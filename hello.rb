require 'sinatra/base'
class HelloApp < Sinatra::Base
  get('/') { 'FUNCIONOU!' }
end