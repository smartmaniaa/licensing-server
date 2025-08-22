require 'dotenv/load'
require 'sinatra/base'
class HelloApp < Sinatra::Base
  get('/') { 'FUNCIONOU!' }
end