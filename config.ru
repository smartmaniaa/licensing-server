if defined?(Rack::Request) && Rack::Request.const_defined?(:ALLOWED_HOSTS)
  Rack::Request::ALLOWED_HOSTS.replace([/./]) # libera todos os hosts externos
end

require './server'
ServerApp.set :bind, '0.0.0.0'
ServerApp.set :port, ENV['PORT'] || 9292
ServerApp.set :environment, :production

run ServerApp