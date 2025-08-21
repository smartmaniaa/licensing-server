require './test'
TestApp.set :protection, false
TestApp.set :bind, '0.0.0.0'
TestApp.set :port, ENV['PORT']
run TestApp
