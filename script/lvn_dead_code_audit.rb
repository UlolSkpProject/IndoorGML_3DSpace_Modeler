# frozen_string_literal: true

require 'ripper'
require 'set'

ROOT = File.expand_path('..', __dir__)
ENTRY = File.join(ROOT, 'indoor3d/application/local_vertex_normalizer.rb')
TARGET_DIR = File.join(ROOT, 'indoor3d/application/local_vertex_normalizer')

Definition = Struct.new(:name, :file, :first_line, :last_line, :kind, keyword_init: true)
AliasEntry = Struct.new(:new_name, :old_name, :file, :line, keyword_init: true)

module AstWalk
  module_function

  def definitions(node, file, result = [])
    return result unless node.is_a?(RubyVM::AbstractSyntaxTree::Node)

    case node.type
    when :DEFN
      result << Definition.new(
        name: node.children[0].to_s,
        file: file,
        first_line: node.first_lineno,
        last_line: node.last_lineno,
        kind: :instance
      )
    when :DEFS
      result << Definition.new(
        name: node.children[1].to_s,
        file: file,
        first_line: node.first_lineno,
        last_line: node.last_lineno,
        kind: :singleton
      )
    end

    node.children.each { |child| definitions(child, file, result) }
    result
  end
end

def ruby_files
  Dir.glob(File.join(ROOT, '**/*.rb')).sort
end

def target_files
  [ENTRY, *Dir.glob(File.join(TARGET_DIR, '*.rb')).sort]
end

def relative(path)
  path.delete_prefix("#{ROOT}/")
end

def resolve_require(from_file, required)
  candidate = File.expand_path("#{required}.rb", File.dirname(from_file))
  File.file?(candidate) ? candidate : nil
end

def load_order(entry, visited = Set.new, output = [])
  return output if visited.include?(entry)
  return output unless File.file?(entry)

  visited << entry
  File.readlines(entry, chomp: true).each do |line|
    match = line.match(/^\s*require_relative\s+['\"]([^'\"]+)['\"]/) 
    next unless match

    dependency = resolve_require(entry, match[1])
    load_order(dependency, visited, output) if dependency
  end
  output << entry
  output
end

def aliases_in(path)
  entries = []
  File.readlines(path, chomp: true).each_with_index do |line, index|
    compact = line.strip
    match = compact.match(/alias_method\s*(?:\(\s*)?:([A-Za-z_]\w*[!?=]?)\s*,\s*:([A-Za-z_]\w*[!?=]?)/)
    if match
      entries << AliasEntry.new(
        new_name: match[1], old_name: match[2], file: path, line: index + 1
      )
      next
    end

    match = compact.match(/^alias\s+:?([A-Za-z_]\w*[!?=]?)\s+:?([A-Za-z_]\w*[!?=]?)/)
    next unless match

    entries << AliasEntry.new(
      new_name: match[1], old_name: match[2], file: path, line: index + 1
    )
  end
  entries
end

def identifier_counts(paths)
  counts = Hash.new(0)
  paths.each do |path|
    source = File.read(path)
    Ripper.lex(source).each do |_position, type, token, _state|
      next unless [:on_ident, :on_const, :on_op].include?(type)
      next unless token.match?(/\A[A-Za-z_]\w*[!?=]?\z/)

      counts[token] += 1
    end
  rescue SyntaxError => error
    warn "LEX ERROR #{relative(path)}: #{error.message}"
  end
  counts
end

files = target_files
all_repo_files = ruby_files
order = load_order(ENTRY)
order_index = order.each_with_index.to_h

definitions = files.flat_map do |path|
  AstWalk.definitions(RubyVM::AbstractSyntaxTree.parse_file(path), path)
rescue SyntaxError => error
  warn "AST ERROR #{relative(path)}: #{error.message}"
  []
end

aliases = files.flat_map { |path| aliases_in(path) }
identifier_count = identifier_counts(all_repo_files)
definition_count = definitions.group_by(&:name).transform_values(&:length)
alias_new_count = aliases.group_by(&:new_name).transform_values(&:length)
alias_old_count = aliases.group_by(&:old_name).transform_values(&:length)

puts '=== LocalVertexNormalizer load order ==='
order.each_with_index do |path, index|
  puts format('%2d. %s', index + 1, relative(path))
end

puts "\n=== Files outside final load order ==="
(files - order).each { |path| puts relative(path) }

puts "\n=== Duplicate method definitions ==="
definitions.group_by { |entry| [entry.kind, entry.name] }
           .select { |_key, entries| entries.length > 1 }
           .sort_by { |(kind, name), _entries| [kind.to_s, name] }
           .each do |(kind, name), entries|
  puts "#{kind} #{name}"
  entries.sort_by do |entry|
    [order_index.fetch(entry.file, 1_000_000), entry.first_line]
  end.each do |entry|
    puts "  #{relative(entry.file)}:#{entry.first_line}-#{entry.last_line}"
  end
  preserved = aliases.select { |entry| entry.old_name == name }
  preserved.each do |entry|
    puts "  alias #{entry.new_name} <- #{entry.old_name} at #{relative(entry.file)}:#{entry.line}"
  end
end

puts "\n=== Alias chain ==="
aliases.sort_by { |entry| [order_index.fetch(entry.file, 1_000_000), entry.line] }.each do |entry|
  puts "#{relative(entry.file)}:#{entry.line} #{entry.new_name} <- #{entry.old_name}"
end

WHITELIST = Set.new(%w[
  initialize normalize normalized?
]).freeze

puts "\n=== Zero-reference candidate methods ==="
definitions.sort_by { |entry| [relative(entry.file), entry.first_line] }.each do |entry|
  next if WHITELIST.include?(entry.name)

  structural_mentions = definition_count[entry.name].to_i +
    alias_new_count[entry.name].to_i + alias_old_count[entry.name].to_i
  non_structural_mentions = identifier_count[entry.name].to_i - structural_mentions
  next unless non_structural_mentions <= 0

  puts "#{entry.kind} #{entry.name} #{relative(entry.file)}:#{entry.first_line}-#{entry.last_line}"
end

puts "\n=== Definition/reference summary ==="
definitions.group_by(&:name).sort.each do |name, entries|
  structural_mentions = definition_count[name].to_i +
    alias_new_count[name].to_i + alias_old_count[name].to_i
  non_structural_mentions = identifier_count[name].to_i - structural_mentions
  puts format(
    '%-64s defs=%-2d aliases_from=%-2d aliases_to=%-2d non_structural_tokens=%d',
    name,
    entries.length,
    alias_old_count[name].to_i,
    alias_new_count[name].to_i,
    non_structural_mentions
  )
end
