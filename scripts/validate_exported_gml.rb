# frozen_string_literal: true

require 'rexml/document'
require 'set'

path = ARGV[0]
abort("Usage: ruby #{File.basename(__FILE__)} path/to/export.gml") if path.to_s.empty?

doc = REXML::Document.new(File.read(path))
ids = Hash.new(0)
REXML::XPath.each(doc, '//*[@gml:id]', { 'gml' => 'http://www.opengis.net/gml/3.2' }) do |element|
  ids[element.attributes['gml:id']] += 1
end
id_set = ids.keys.to_set

errors = []
ids.each { |id, count| errors << "Duplicate gml:id: #{id}" if count > 1 }

REXML::XPath.each(doc, '//*[@xlink:href]', { 'xlink' => 'http://www.w3.org/1999/xlink' }) do |element|
  href = element.attributes['xlink:href'].to_s
  next unless element.expanded_name.start_with?('core:')

  errors << "Internal xlink missing #: #{href}" unless href.start_with?('#')
  target = href.delete_prefix('#')
  errors << "Missing xlink target: #{href}" unless id_set.include?(target)
end

%w[navi:class navi:function navi:usage].each do |tag|
  REXML::XPath.each(doc, "//#{tag}", { 'navi' => 'http://www.opengis.net/indoorgml/1.0/navigation' }) do |element|
    value = element.text.to_s
    errors << "Empty #{tag}" if value.empty?
    errors << "Element type leaked into navi:class: #{value}" if tag == 'navi:class' && %w[GeneralSpace TransitionSpace ConnectionSpace].include?(value)
  end
end

state_storeys = {}
REXML::XPath.each(doc, '//core:State', { 'core' => 'http://www.opengis.net/indoorgml/1.0/core' }) do |state|
  state_id = state.attributes['gml:id']
  description = REXML::XPath.first(state, 'gml:description', { 'gml' => 'http://www.opengis.net/gml/3.2' })&.text.to_s
  state_storeys[state_id] = description[/storey="([^"]+)"/, 1]
end

REXML::XPath.each(doc, '//*[starts-with(local-name(), "GeneralSpace") or starts-with(local-name(), "TransitionSpace") or starts-with(local-name(), "ConnectionSpace")]') do |cell|
  description = REXML::XPath.first(cell, 'gml:description', { 'gml' => 'http://www.opengis.net/gml/3.2' })&.text.to_s
  cell_storey = description[/storey="([^"]+)"/, 1]
  errors << "CellSpace missing storey: #{cell.attributes['gml:id']}" if cell_storey.to_s.empty?
  duality = REXML::XPath.first(cell, 'core:duality', { 'core' => 'http://www.opengis.net/indoorgml/1.0/core' })
  state_id = duality&.attributes&.[]('xlink:href').to_s.delete_prefix('#')
  next if state_id.empty?

  errors << "State storey mismatch: #{state_id}" unless state_storeys[state_id] == cell_storey
end

if errors.empty?
  puts 'GML validation checks passed.'
else
  warn errors.join("\n")
  exit 1
end
