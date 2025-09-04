# Usa a imagem oficial do Ruby como base
FROM ruby:3.3

# Instala dependências do sistema necessárias para a gem 'pg' (PostgreSQL)
RUN apt-get update -qq && apt-get install -y build-essential libpq-dev

# Cria e define o diretório de trabalho dentro do container
WORKDIR /app

# Copia Gemfile e Gemfile.lock (para otimizar camada de cache do bundle)
COPY Gemfile Gemfile.lock ./

# --- INÍCIO DA CORREÇÃO ---
# Limpa qualquer cache antigo do Bundler e remove gems antigas
RUN rm -rf /usr/local/bundle/gems/*
RUN gem cleanup
# --- FIM DA CORREÇÃO ---

# Instala as gems definidas no Gemfile
RUN bundle install

# Copia o resto do código da aplicação para o diretório de trabalho
COPY . .

# Expõe a porta que o Puma (servidor) irá usar
EXPOSE 9292

# O comando principal que será executado quando o container iniciar

CMD ["bundle", "exec", "puma", "-b", "tcp://0.0.0.0:9292"]