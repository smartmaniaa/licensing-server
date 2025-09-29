require 'bundler/setup'
Bundler.require

if defined?(Rack::Request) && Rack::Request.const_defined?(:ALLOWED_HOSTS)
  Rack::Request::ALLOWED_HOSTS.replace([/./]) # libera todos os hosts externos
end

require './server'
SmartManiaaApp.set :bind, '0.0.0.0'
SmartManiaaApp.set :port, ENV['PORT'] || 9292
SmartManiaaApp.set :environment, :production

run SmartManiaaApp