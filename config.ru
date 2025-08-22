if defined?(Rack::Request) && Rack::Request.const_defined?(:ALLOWED_HOSTS)
  Rack::Request::ALLOWED_HOSTS.replace([/./]) # libera todos os hosts externos
end

require './server'

HelloApp.set :bind, '0.0.0.0'
HelloApp.set :port, ENV['PORT'] || 9292
HelloApp.set :environment, :production
run ServerApp