require './hello'
HelloApp.set :protection, false
HelloApp.set :bind, '0.0.0.0'
HelloApp.set :port, ENV['PORT']
run HelloApp
