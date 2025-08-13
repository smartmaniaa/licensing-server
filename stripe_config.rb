# ---- stripe_config.rb (Arquivo Novo) ----
require 'stripe'

# Define a chave secreta da API para toda a aplicação.
# Trate esta chave como uma senha!
#Stripe.api_key = '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_AQUI' # <<<<<<< COLOQUE SUA CHAVE AQUI
Stripe.api_key = ENV['STRIPE_API_KEY']