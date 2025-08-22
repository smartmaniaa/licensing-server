# Imagem oficial Ruby moderna e segura
FROM ruby:3.3

# Instala libs de build essenciais (para gems nativas, como pg/nokogiri)
RUN apt-get update -qq && apt-get install -y build-essential libpq-dev

# Define a pasta padrão do app
WORKDIR /app

# Copia Gemfile e Gemfile.lock (para otimizar camada de cache do bundle)
COPY Gemfile Gemfile.lock ./
RUN bundle install

# Copia todo o restante do código
COPY . .

# Expõe a mesma porta do compose (9292)
EXPOSE 9292

# Entrypoint/CMD padrão (será sobrescrito pelo docker-compose, mas é boa prática deixar aqui também)
CMD ["bundle", "exec", "puma", "-b", "tcp://0.0.0.0:9292"]
