# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class EditorSession
        class ValidationCameraController
          DEFAULT_MARGIN = 1.4
          MIN_FRAME_SIZE = 1.0e-4
          MIN_CAMERA_DISTANCE = 1.0e-4
          ORIENTATION_DOT_TOLERANCE = 1.0e-6
      
          ORIENTATIONS = %i[
            keep
            top
            bottom
            front
            back
            left
            right
            iso
          ].freeze
      
          ZOOM_MODES = %i[
            none
            selected
            extents
            bounds
          ].freeze
      
          PROJECTIONS = %i[keep parallel perspective].freeze
      
          SQRT_3 = Math.sqrt(3.0)
          SQRT_6 = Math.sqrt(6.0)
      
          ORIENTATION_BASES = {
            top: {
              front: [0.0, 0.0, -1.0].freeze,
              up: [0.0, 1.0, 0.0].freeze
            }.freeze,
            bottom: {
              front: [0.0, 0.0, 1.0].freeze,
              up: [0.0, -1.0, 0.0].freeze
            }.freeze,
            front: {
              front: [0.0, 1.0, 0.0].freeze,
              up: [0.0, 0.0, 1.0].freeze
            }.freeze,
            back: {
              front: [0.0, -1.0, 0.0].freeze,
              up: [0.0, 0.0, 1.0].freeze
            }.freeze,
            left: {
              front: [1.0, 0.0, 0.0].freeze,
              up: [0.0, 0.0, 1.0].freeze
            }.freeze,
            right: {
              front: [-1.0, 0.0, 0.0].freeze,
              up: [0.0, 0.0, 1.0].freeze
            }.freeze,
            iso: {
              front: [-1.0 / SQRT_3, 1.0 / SQRT_3, -1.0 / SQRT_3].freeze,
              up: [-1.0 / SQRT_6, 1.0 / SQRT_6, 2.0 / SQRT_6].freeze
            }.freeze
          }.freeze
      
          def initialize(camera_factory: nil)
            @camera_factory = camera_factory
            clear_state
          end
      
          # Capture before the deferred camera callback runs.
          def capture(model)
            validate_model!(model)
            ensure_focus(model)
            { ok: true, captured: true }
          rescue StandardError => e
            error("Camera Snapshot 실패: #{e.class}: #{e.message}")
          end
      
          def captured_model?(model)
            @model && @original_state && @model.equal?(model)
          end
      
          def discard
            clear_state
            { ok: true, discarded: true }
          end
      
          def apply(model, orientation: :keep, zoom: :none, projection: :parallel, target: nil, margin: nil)
            orientation = normalize_orientation(orientation)
            zoom = normalize_zoom(zoom)
            projection = normalize_projection(projection)
            margin = normalize_margin(margin || default_margin_for(zoom))
            validate_model!(model)
            target = resolve_zoom_target(model, zoom, target)
      
            ensure_focus(model)
            projection_changed = apply_projection(model, projection)
            orientation_changed = apply_orientation(model, orientation)
            zoom_applied = apply_zoom(model, zoom, target, margin)
            invalidate(model)
      
            {
              ok: true,
              projection_changed: projection_changed,
              orientation_changed: orientation_changed,
              zoom_applied: zoom_applied
            }
          rescue StandardError => e
            restored = restore if @original_state
            error("Camera 적용 중 오류가 발생했습니다: #{e.message}" + (restored && !restored[:ok] ? "; #{restored[:message]}" : ""))
          end
      
          def restore
            return { ok: true, restored: false } unless @model && @original_state
      
            model = @model
            if defined?(Sketchup) && Sketchup.respond_to?(:active_model)
              current_model = Sketchup.active_model
              if current_model && !current_model.equal?(model)
                clear_state
                return { ok: true, restored: false }
              end
            end
            original_state = @original_state
            unless valid_model?(model)
              clear_state
              return { ok: true, restored: false }
            end
      
            view = active_view(model)
            view.camera = original_state.fetch(:camera)
            invalidate(model)
            clear_state
            { ok: true, restored: true }
          rescue StandardError => e
            error("Camera 복원 중 오류가 발생했습니다: #{e.message}")
          end
      
          private
      
          def ensure_focus(model)
            clear_state if @model && !@model.equal?(model) # Model replacement must not write to the previous Model.
            return if @model.equal?(model) && @original_state
      
            begin_focus(model)
          end
      
          def begin_focus(model)
            view = active_view(model)
            original_camera = view.camera
            raise '현재 Camera를 확인할 수 없습니다.' unless original_camera
      
            snapshot = copy_camera(original_camera)
            working_camera = copy_camera(original_camera)
            @model = model
            @original_state = { camera: snapshot }
            view.camera = working_camera
          rescue StandardError
            clear_state
            raise
          end
      
          def apply_projection(model, projection)
            return false if projection == :keep
      
            camera = active_camera(model)
            perspective = projection == :perspective
            return false if camera.perspective? == perspective
      
            camera.perspective = perspective
            true
          end
      
          def apply_orientation(model, orientation)
            return false if orientation == :keep
      
            camera = active_camera(model)
            basis = ORIENTATION_BASES.fetch(orientation)
            return false if orientation_matches?(camera, basis)
      
            eye = coordinates(camera.eye)
            target = coordinates(camera.target)
            distance = vector_length(coordinate_subtract(eye, target))
            distance = MIN_CAMERA_DISTANCE if distance < MIN_CAMERA_DISTANCE
      
            front = basis.fetch(:front)
            new_eye = coordinate_subtract(target, coordinate_scale(front, distance))
            height = positive_camera_height(camera)
            camera.set(build_point(new_eye), build_point(target), build_vector(basis.fetch(:up)))
            camera.height = height if height && !camera.perspective?
            true
          end
      
          def orientation_matches?(camera, basis)
            camera_front = normalize_coordinates(coordinates(camera.zaxis))
            camera_up = normalize_coordinates(coordinates(camera.yaxis))
            requested_front = basis.fetch(:front)
            requested_up = basis.fetch(:up)
      
            vector_matches?(camera_front, requested_front) &&
              vector_matches?(camera_up, requested_up)
          rescue StandardError
            false
          end
      
          def vector_matches?(first, second)
            coordinate_dot(first, second) >= 1.0 - ORIENTATION_DOT_TOLERANCE
          end
      
          def apply_zoom(model, zoom, target, margin)
            case zoom
            when :none
              false
            when :selected
              active_view(model).zoom(target)
              apply_selected_margin(model, margin)
              true
            when :extents
              active_view(model).zoom_extents
              true
            when :bounds
              frame_bounds(model, target, margin)
              true
            else
              raise ArgumentError, "지원하지 않는 Zoom 방식입니다: #{zoom}"
            end
          end
      
          def resolve_zoom_target(model, zoom, target)
            case zoom
            when :selected
              selected = target || model_selection(model)
              raise ArgumentError, 'Zoom할 선택 Entity가 없습니다.' if empty_zoom_target?(selected)
      
              selected
            when :bounds
              normalize_bounds(target)
            else
              target
            end
          end
      
          def model_selection(model)
            return nil unless model.respond_to?(:selection)
      
            selection = model.selection
            return selection.to_a if selection.respond_to?(:to_a)
      
            selection
          end
      
          def empty_zoom_target?(target)
            return true if target.nil?
            return target.empty? if target.respond_to?(:empty?)
      
            false
          end
      
          def frame_bounds(model, bounds, margin)
            view = active_view(model)
            camera = active_camera(model)
            minimum = bounds.fetch(:min)
            maximum = bounds.fetch(:max)
            center = 3.times.map { |axis| (minimum[axis] + maximum[axis]) * 0.5 }
            corners = bounds_corners(minimum, maximum)
      
            right = normalize_coordinates(coordinates(camera.xaxis))
            up = normalize_coordinates(coordinates(camera.yaxis))
            front = normalize_coordinates(coordinates(camera.zaxis))
            offsets = corners.map { |corner| coordinate_subtract(corner, center) }
      
            half_width = offsets.map { |offset| coordinate_dot(offset, right).abs }.max
            half_height = offsets.map { |offset| coordinate_dot(offset, up).abs }.max
            half_depth = offsets.map { |offset| coordinate_dot(offset, front).abs }.max
            aspect = viewport_aspect(view, camera)
      
            height = [half_height * 2.0, half_width * 2.0 / aspect, MIN_FRAME_SIZE].max * margin
            if camera.perspective?
              fov = camera.respond_to?(:fov) ? camera.fov.to_f : 35.0
              raise ArgumentError, 'Camera FOV가 유효하지 않습니다.' unless fov.finite? && fov > 0.0 && fov < 180.0
      
              tangent = Math.tan(fov * Math::PI / 360.0)
              if camera.respond_to?(:fov_is_height?) && !camera.fov_is_height?
                tangent /= aspect
              end
              distance = half_depth + [half_height, half_width / aspect, MIN_FRAME_SIZE].max * margin / tangent
              distance = [distance, MIN_CAMERA_DISTANCE].max
            else
              distance = [half_depth * 2.0, height * 2.0, MIN_CAMERA_DISTANCE].max
            end
            eye = coordinate_subtract(center, coordinate_scale(front, distance))
      
            camera.set(build_point(eye), build_point(center), build_vector(up))
            camera.height = height unless camera.perspective?
          end
      
          def normalize_bounds(value)
            raise ArgumentError, 'Zoom할 Bounds가 없습니다.' unless value
      
            minimum, maximum = if value.respond_to?(:each_pair)
                                 [
                                   coordinates(value[:min] || value['min']),
                                   coordinates(value[:max] || value['max'])
                                 ]
                               elsif value.respond_to?(:min) && value.respond_to?(:max)
                                 [coordinates(value.min), coordinates(value.max)]
                               else
                                 raise ArgumentError, 'Bounds 형식을 확인할 수 없습니다.'
                               end
      
            unless minimum.length == 3 && maximum.length == 3
              raise ArgumentError, 'Bounds는 min/max 3차원 좌표가 필요합니다.'
            end
            unless (minimum + maximum).all? { |coordinate| coordinate.finite? }
              raise ArgumentError, 'Bounds에 유효하지 않은 좌표가 있습니다.'
            end
            unless 3.times.all? { |axis| minimum[axis] <= maximum[axis] }
              raise ArgumentError, 'Bounds의 min/max 순서가 올바르지 않습니다.'
            end
      
            { min: minimum, max: maximum }
          end
      
          def bounds_corners(minimum, maximum)
            [minimum[0], maximum[0]].product(
              [minimum[1], maximum[1]],
              [minimum[2], maximum[2]]
            )
          end
      
          def normalize_orientation(value)
            orientation = value.to_s.downcase.to_sym
            raise ArgumentError, "지원하지 않는 Camera 방향입니다: #{value}" unless ORIENTATIONS.include?(orientation)
      
            orientation
          end
      
          def normalize_projection(value)
            projection = value.to_s.downcase.to_sym
            raise ArgumentError, "지원하지 않는 Camera 투영 방식입니다: #{value}" unless PROJECTIONS.include?(projection)
      
            projection
          end
      
          def normalize_zoom(value)
            zoom = value.to_s.downcase.to_sym
            raise ArgumentError, "지원하지 않는 Zoom 방식입니다: #{value}" unless ZOOM_MODES.include?(zoom)
      
            zoom
          end
      
          def default_margin_for(zoom)
            zoom == :bounds ? DEFAULT_MARGIN : 1.0
          end
      
          def apply_selected_margin(model, margin)
            return if margin == 1.0
      
            camera = active_camera(model)
            height = positive_camera_height(camera)
            camera.height = height * margin if height
          end
      
          def normalize_margin(value)
            margin = Float(value)
            raise ArgumentError, 'Camera margin은 0보다 커야 합니다.' unless margin.finite? && margin.positive?
      
            margin
          rescue TypeError, ArgumentError => e
            raise e if e.message.start_with?('Camera margin')
      
            raise ArgumentError, 'Camera margin은 0보다 큰 숫자여야 합니다.'
          end
      
          def copy_camera(camera)
            return @camera_factory.call(camera) if @camera_factory
      
            perspective = camera.perspective?
            arguments = [camera.eye, camera.target, camera.up, perspective]
            arguments << camera.fov if perspective
            copy = Sketchup::Camera.new(*arguments)
            if !perspective && copy.respond_to?(:height=)
              height = positive_camera_height(camera)
              copy.height = height if height
            end
            if copy.respond_to?(:aspect_ratio=) && camera.respond_to?(:aspect_ratio)
              copy.aspect_ratio = camera.aspect_ratio
            end
            copy
          end
      
          def positive_camera_height(camera)
            return nil unless camera.respond_to?(:height)
            return nil if camera.respond_to?(:perspective?) && camera.perspective?
      
            height = camera.height.to_f
            height.positive? && height.finite? ? height : nil
          rescue StandardError
            nil
          end
      
          def viewport_aspect(view, camera)
            camera_aspect = camera.aspect_ratio.to_f if camera.respond_to?(:aspect_ratio)
            return camera_aspect if camera_aspect&.finite? && camera_aspect.positive?
      
            width = view.respond_to?(:vpwidth) ? view.vpwidth.to_f : 0.0
            height = view.respond_to?(:vpheight) ? view.vpheight.to_f : 0.0
            return 1.0 unless width.positive? && height.positive?
      
            aspect = width / height
            aspect.finite? && aspect.positive? ? aspect : 1.0
          end
      
          def active_view(model)
            raise 'SketchUp Model을 확인할 수 없습니다.' unless valid_model?(model)
            raise 'SketchUp View를 확인할 수 없습니다.' unless model.respond_to?(:active_view)
      
            view = model.active_view
            raise 'SketchUp View를 확인할 수 없습니다.' unless view
      
            view
          end
      
          def active_camera(model)
            view = active_view(model)
            raise '현재 Camera를 확인할 수 없습니다.' unless view.respond_to?(:camera)
      
            camera = view.camera
            raise '현재 Camera를 확인할 수 없습니다.' unless camera
      
            camera
          end
      
          def validate_model!(model)
            raise ArgumentError, 'SketchUp Model이 없습니다.' unless model
            raise ArgumentError, 'SketchUp Model이 유효하지 않습니다.' unless valid_model?(model)
      
            active_view(model)
          end
      
          def valid_model?(model)
            return false unless model
            return model.valid? if model.respond_to?(:valid?)
      
            true
          rescue StandardError
            false
          end
      
          def invalidate(model)
            view = active_view(model)
            view.invalidate if view.respond_to?(:invalidate)
          end
      
          def coordinates(value)
            if value.respond_to?(:x) && value.respond_to?(:y) && value.respond_to?(:z)
              return [value.x.to_f, value.y.to_f, value.z.to_f]
            end
      
            coordinates = Array(value).map { |coordinate| Float(coordinate) }
            raise ArgumentError, '3차원 좌표가 필요합니다.' unless coordinates.length == 3
      
            raise ArgumentError, '3차원 좌표가 필요합니다.' unless coordinates.all?(&:finite?)
            coordinates
          end
      
          def normalize_coordinates(vector)
            length = vector_length(vector)
            raise ArgumentError, 'Camera 축의 길이가 0입니다.' if length < MIN_CAMERA_DISTANCE
      
            coordinate_scale(vector, 1.0 / length)
          end
      
          def vector_length(vector)
            Math.sqrt(coordinate_dot(vector, vector))
          end
      
          def coordinate_dot(first, second)
            first[0] * second[0] + first[1] * second[1] + first[2] * second[2]
          end
      
          def coordinate_add(first, second)
            [first[0] + second[0], first[1] + second[1], first[2] + second[2]]
          end
      
          def coordinate_subtract(first, second)
            [first[0] - second[0], first[1] - second[1], first[2] - second[2]]
          end
      
          def coordinate_scale(vector, scale)
            [vector[0] * scale, vector[1] * scale, vector[2] * scale]
          end
      
          def build_point(coordinates)
            Geom::Point3d.new(*coordinates)
          end
      
          def build_vector(coordinates)
            Geom::Vector3d.new(*coordinates)
          end
      
          def clear_state
            @model = nil
            @original_state = nil
          end
      
          def error(message)
            { ok: false, message: message }
          end
        end
      end
    end
  end
end
