# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module StoreyFilter
        PART_PATTERN = /\A([FB])(\d{1,2})\z/

        module_function

        def options_for(cell_spaces)
          labels = Array(cell_spaces).each_with_object([]) do |cell_space, result|
            next unless cell_space&.valid?

            result.concat(labels_for(cell_space.storey))
          end
          labels.uniq.sort.map { |label| { value: label, label: label } }
        end

        def normalize_labels(values)
          Array(values).map { |value| normalize_label(value) }.compact.uniq.sort
        end

        def normalize_label(value)
          match = value.to_s.strip.upcase.match(PART_PATTERN)
          return nil unless match

          "#{match[1]}#{format('%02d', match[2].to_i)}"
        end

        def labels_for(value)
          parts = value.to_s.strip.upcase.split('~', 2)
          from = parse_part(parts[0])
          to = parse_part(parts[1] || parts[0])
          return [CellSpace::DEFAULT_STOREY] if from.nil?
          return [format_part(from)] if to.nil?

          if from[:kind] == to[:kind]
            min, max = [from[:level], to[:level]].minmax
            return (min..max).map { |level| "#{from[:kind]}#{format('%02d', level)}" }
          end

          [format_part(from), format_part(to)].compact.uniq
        end

        def parse_part(value)
          match = value.to_s.strip.upcase.match(PART_PATTERN)
          return nil unless match

          level = [[match[2].to_i, 1].max, 99].min
          { kind: match[1], level: level }
        end

        def format_part(part)
          "#{part[:kind]}#{format('%02d', part[:level])}"
        end
      end
    end
  end
end
