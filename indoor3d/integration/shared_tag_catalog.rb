# frozen_string_literal: true

require 'json'
require_relative '../domain/cell_space_type'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      # A compact, immutable snapshot. Classification never reads the source file.
      class SharedTagCatalog
        BUILDING_TYPES = { 'subway' => '지하철', 'public' => '공공기관' }.freeze
        DIVISIONS = { '지하철' => 'subway', '공공기관' => 'public', '공공시설건물' => 'public' }.freeze
        COMMON_DIVISIONS = %w[구조 공통].freeze
        FLOOR = '[FB](?:0[1-9]|[1-9][0-9])'
        PRIMARY_CODES = %w[FF IP IF CV MV RM IS].freeze
        PRIMARY_CODE = "(?:#{PRIMARY_CODES.join('|')})"
        CODE_PATTERN = /\A#{PRIMARY_CODE}_[A-Z0-9]+(?:_\d+)?\z/.freeze
        TAG_PATTERN = /\A(#{FLOOR})(#{FLOOR})_((#{PRIMARY_CODE})_([A-Z0-9]+)(?:_(\d+))?)\z/.freeze
        ROOM = [CellSpaceType::GENERAL, 'Room'].freeze
        SPECIAL_TYPES = {
          '문' => [CellSpaceType::CONNECTION, 'Door'].freeze,
          '창문' => [CellSpaceType::GEOMETRY_ONLY, 'Window'].freeze,
          '엘리베이터' => [CellSpaceType::TRANSITION, 'Elevator'].freeze,
          '계단' => [CellSpaceType::TRANSITION, 'Stair'].freeze,
          '에스컬레이터' => [CellSpaceType::TRANSITION, 'Stair'].freeze
        }.freeze

        attr_reader :path, :error

        def self.default_path
          base = ENV['APPDATA'].to_s.strip
          base = File.join(Dir.home, 'AppData', 'Roaming') if base.empty?
          File.join(base, 'SketchUp', 'SketchUp 2026', 'SketchUp', 'SeoulSpace', 'tag_catalog.json')
        end

        def self.load(path: default_path)
          source = path
          # Also works if IndoorGML loads before Tag Helper's one-time migration.
          legacy = File.join(File.dirname(path), 'TagHelper', 'catalog.json')
          source = legacy if !File.exist?(source) && File.file?(legacy)
          data = JSON.parse(File.read(source, encoding: 'bom|utf-8'))
          raise '객체코드표의 categories 형식이 올바르지 않습니다.' unless data.is_a?(Hash) && data['categories'].is_a?(Array)

          new(data['categories'], path: path)
        rescue StandardError => e
          new([], path: path, error: e.message)
        end

        def initialize(categories, path: nil, error: nil)
          @path = path
          @error = error
          @rules = BUILDING_TYPES.to_h { |key, _| [key, {}] }
          Array(categories).each { |row| add_row(row) }
          @rules.each_value(&:freeze)
          @rules.freeze
          freeze
        end

        def classify(tag_name, building_type:)
          match = TAG_PATTERN.match(tag_name.to_s)
          return nil unless match

          special_type = @rules.fetch(building_type.to_s, {})[match[3]]
          return special_type if special_type
          return ROOM if match[4] == 'RM' || match[5] == 'RM'

          nil
        end

        private

        def add_row(row)
          division = row.fetch('division').to_s.strip
          buildings = COMMON_DIVISIONS.include?(division) ? BUILDING_TYPES.keys : [DIVISIONS[division]].compact
          return if buildings.empty?

          name = row.fetch('minor_category').to_s.gsub(/\s+/, '').sub(/(?:\(공간\)|（공간）)\z/, '')
          target = SPECIAL_TYPES[name]
          return unless target

          code = "#{row.fetch('major_code').to_s.strip}_#{row.fetch('minor_code').to_s.strip}".upcase
          raise "TAG 코드 형식이 올바르지 않습니다: #{code}" unless CODE_PATTERN.match?(code)

          codes = if row['editable_facility_code_suffix'] == true
                    raise "시설번호를 찾을 수 없습니다: #{code}" unless code.match?(/\d{2}\z/)

                    (0..99).map { |number| code.sub(/\d+\z/, format('%02d', number)) }
                  else
                    [code]
                  end
          buildings.each do |building|
            codes.each do |key|
              previous = @rules[building][key]
              raise "TAG 분류가 중복됩니다: #{division}/#{key}" if previous && previous != target

              @rules[building][key] = target
            end
          end
        end
      end
    end
  end
end
