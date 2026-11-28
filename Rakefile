# frozen_string_literal: true

require "standard/rake"
require "rake/testtask"

# The suite covers what needs no mail and no model: file layouts, the body cap,
# the ledger, config parsing and run selection.
Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.pattern = "test/**/*_test.rb"
  t.warning = false
end

task default: %i[test standard]
