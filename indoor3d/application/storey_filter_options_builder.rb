# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module StoreyFilterOptionsBuilder
        module_function

        def build(cell_spaces)
          labels = Array(cell_spaces).each_with_object([]) do |cell_space, result|
            next unless cell_space&.valid?

            result.concat(StoreyFilterParser.labels_for(cell_space.storey))
          end
          labels.uniq.sort.map { |label| { value: label, label: label } }
        end
      end
    end
  end
end
