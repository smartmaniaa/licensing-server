require 'dotenv/load'
require 'sinatra/base'
class SmartManiaaApp < Sinatra::Base
  get('/') { 'FUNCIONOU!' }
end