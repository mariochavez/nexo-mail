# frozen_string_literal: true

source "https://rubygems.org"

# Dependencies are declared in nexo_mail.gemspec.
gemspec

# Upgrade test bed: run against the local nexo_ai checkout (ruby_llm 2.2 port).
gem "nexo_ai", path: "../nexo"

group :development do
  gem "rake"
  gem "standard" # linter + formatter (github.com/standardrb/standard)
end
