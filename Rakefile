# encoding: utf-8

require 'rubygems'
require 'bundler'
begin
  Bundler.setup(:default, :development)
rescue Bundler::BundlerError => e
  $stderr.puts e.message
  $stderr.puts "Run `bundle install` to install missing gems"
  exit e.status_code
end
require 'rake'
require_relative 'lib/sqewer/version'
require 'jeweler'
Jeweler::Tasks.new do |gem|
  # gem is a Gem::Specification... see http://guides.rubygems.org/specification-reference/ for more options
  gem.version = Sqewer::VERSION
  gem.name = "sqewer"
  gem.homepage = "https://gitlab.wetransfer.net/julik/sqewer"
  gem.license = "MIT"
  gem.description = %Q{Process jobs from SQS}
  gem.summary = %Q{A full-featured library for all them worker needs}
  gem.email = "me@julik.nl"
  gem.authors = ["Julik Tarkhanov"]
  gem.executables = ["sqewer", "sqewer_rails"]
  # dependencies defined in Gemfile
end
Jeweler::RubygemsDotOrgTasks.new

require 'rspec/core'
require 'rspec/core/rake_task'
RSpec::Core::RakeTask.new(:spec) do |spec|
  spec.pattern = FileList['spec/**/*_spec.rb']
end

# desc "Code coverage detail"
# task :simplecov do
#   ENV['COVERAGE'] = "true"
#   Rake::Task['spec'].execute
# end

task :default => :spec
