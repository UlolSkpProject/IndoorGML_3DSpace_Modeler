# frozen_string_literal: true

require 'digest'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module PrecisionValidation
        module LvnState
          DICTIONARY_NAME = 'IndoorGml'
          FAILED_KEY = 'lvn_failed'
          FAILED_SIGNATURE_KEY = 'lvn_failed_geometry_signature'
          SIGNATURE_VERSION = 'lvn-geometry-v1'
          UNAVAILABLE_SIGNATURE = "#{SIGNATURE_VERSION}:unavailable"

          module_function

          def group_for(candidate)
            return candidate.valid_sketchup_group if candidate.respond_to?(:valid_sketchup_group)
            return candidate.sketchup_group if candidate.respond_to?(:sketchup_group)

            candidate
          rescue StandardError
            nil
          end

          def valid_group?(group)
            return false if group.nil?
            return true unless group.respond_to?(:valid?)

            group.valid? == true
          rescue StandardError
            false
          end

          def failed?(candidate)
            group = group_for(candidate)
            return false unless valid_group?(group)

            value = group.get_attribute(DICTIONARY_NAME, FAILED_KEY, false)
            value == true || value.to_s.casecmp('true').zero?
          rescue StandardError
            false
          end

          def failure_signature(candidate)
            group = group_for(candidate)
            return nil unless valid_group?(group)

            value = group.get_attribute(DICTIONARY_NAME, FAILED_SIGNATURE_KEY)
            value.to_s.empty? ? nil : value.to_s
          rescue StandardError
            nil
          end

          def geometry_changed_since_failure?(candidate)
            group = group_for(candidate)
            return false unless valid_group?(group)
            return false unless failed?(group)

            stored = failure_signature(group)
            return true if stored.nil?

            current = geometry_signature(group)
            return false if current.nil?

            stored != current
          end

          def failed_and_unchanged?(candidate)
            failed?(candidate) && !geometry_changed_since_failure?(candidate)
          end

          def set_failed(candidate, failed, signature: nil)
            group = group_for(candidate)
            return false unless valid_group?(group)

            target = failed == true
            raw_value = group.get_attribute(DICTIONARY_NAME, FAILED_KEY)
            current = raw_value == true || raw_value.to_s.casecmp('true').zero?
            stored_signature = failure_signature(group)
            target_signature = if target
                                 signature || geometry_signature(group) || UNAVAILABLE_SIGNATURE
                               end

            changed = raw_value.nil? || current != target
            changed ||= target && stored_signature != target_signature
            changed ||= !target && !stored_signature.nil?
            return false unless changed

            group.set_attribute(DICTIONARY_NAME, FAILED_KEY, target)
            if target
              group.set_attribute(
                DICTIONARY_NAME,
                FAILED_SIGNATURE_KEY,
                target_signature
              )
            elsif group.respond_to?(:delete_attribute)
              group.delete_attribute(DICTIONARY_NAME, FAILED_SIGNATURE_KEY)
            end
            true
          rescue StandardError => e
            log("LVN state write failed: #{e.class}: #{e.message}")
            false
          end

          def geometry_signature(candidate)
            group = group_for(candidate)
            return nil unless valid_group?(group)
            return nil unless group.respond_to?(:definition)

            definition = group.definition
            return nil unless definition&.respond_to?(:entities)

            records = []
            records << "version|#{SIGNATURE_VERSION}"
            records << "definition|#{definition_identity(definition)}"

            entities = definition.entities
            edges = sketchup_entities_of_type(entities, :Edge)
            faces = sketchup_entities_of_type(entities, :Face)
            vertices = collect_vertices(edges, faces)

            vertices.map { |vertex| "vertex|#{point_key(vertex.position)}" }
                    .sort
                    .each { |record| records << record }

            edges.map { |edge| edge_record(edge) }
                 .compact
                 .sort
                 .each { |record| records << record }

            faces.map { |face| face_record(face) }
                 .compact
                 .sort
                 .each { |record| records << record }

            Digest::SHA256.hexdigest(records.join("\n"))
          rescue StandardError => e
            log("LVN geometry signature failed: #{e.class}: #{e.message}")
            nil
          end

          def definition_identity(definition)
            return definition.guid.to_s if definition.respond_to?(:guid)
            return definition.persistent_id.to_s if definition.respond_to?(:persistent_id)

            definition.object_id.to_s
          rescue StandardError
            definition.object_id.to_s
          end
          private_class_method :definition_identity

          def sketchup_entities_of_type(entities, constant_name)
            return [] unless entities
            return [] unless defined?(Sketchup)
            return [] unless Sketchup.const_defined?(constant_name)

            entities.grep(Sketchup.const_get(constant_name))
          rescue StandardError
            []
          end
          private_class_method :sketchup_entities_of_type

          def collect_vertices(edges, faces)
            (Array(edges).flat_map { |edge| Array(edge.vertices) } +
              Array(faces).flat_map { |face| Array(face.vertices) }).uniq
          rescue StandardError
            []
          end
          private_class_method :collect_vertices

          def edge_record(edge)
            points = Array(edge.vertices).map { |vertex| point_key(vertex.position) }
            return nil unless points.length == 2

            "edge|#{points.sort.join('|')}"
          rescue StandardError
            nil
          end
          private_class_method :edge_record

          def face_record(face)
            normal = face.respond_to?(:normal) ? vector_key(face.normal) : 'n/a'
            loops = Array(face.loops).map do |loop|
              type = face.respond_to?(:outer_loop) && loop == face.outer_loop ? 'outer' : 'inner'
              points = Array(loop.vertices).map { |vertex| point_key(vertex.position) }
              next if points.empty?

              "#{type}|#{canonical_cycle(points).join('|')}"
            end.compact.sort

            "face|normal=#{normal}|#{loops.join('||')}"
          rescue StandardError
            nil
          end
          private_class_method :face_record

          def canonical_cycle(values)
            rows = Array(values)
            return rows if rows.length <= 1

            rows.each_index.map { |index| rows.rotate(index) }.min
          end
          private_class_method :canonical_cycle

          def point_key(point)
            [point.x, point.y, point.z].map { |value| float_key(value) }.join(',')
          end
          private_class_method :point_key

          def vector_key(vector)
            [vector.x, vector.y, vector.z].map { |value| float_key(value) }.join(',')
          end
          private_class_method :vector_key

          def float_key(value)
            [value.to_f].pack('G').unpack1('H*')
          end
          private_class_method :float_key

          def log(message)
            return unless defined?(IndoorCore::Logger)
            return unless IndoorCore::Logger.respond_to?(:puts)

            IndoorCore::Logger.puts("[IndoorGML] #{message}")
          rescue StandardError
            nil
          end
          private_class_method :log
        end

      end
    end
  end
end
