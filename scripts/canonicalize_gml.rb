# frozen_string_literal: true

require 'rexml/document'
require 'rexml/formatters/pretty'

abort("Usage: ruby #{File.basename(__FILE__)} input.gml [output.gml]") if ARGV[0].to_s.empty?

input_path = ARGV[0]
output_path = ARGV[1] || input_path

doc = REXML::Document.new(File.read(input_path, encoding: 'UTF-8'))

formatter = REXML::Formatters::Pretty.new(2)
formatter.compact = true

content = +''
formatter.write(doc, content)
content << "\n" unless content.end_with?("\n")

File.write(output_path, content, encoding: 'UTF-8')
