# template.rb
gem 'sidekiq'

gem_group :development, :test do
  gem 'dotenv-rails'
  gem 'factory_bot_rails'
  gem 'rspec-rails'
  gem 'faker'
  gem 'shoulda-matchers'
end

gem_group :development do
  gem 'letter_opener'
end

gem_group :test do
  gem 'database_cleaner-active_record'
  gem 'simplecov', require: false
end


# === Após instalar dependências ===
after_bundle do
  generate "rspec:install"

  # ---- FactoryBOT ----
  file 'spec/support/factory_bot.rb', <<-RUBY
    # spec/support/factory_bot.rb

    RSpec.configure do |config|
      config.include FactoryBot::Syntax::Methods
    end
  RUBY

  # ---- DatabaseCleaner ----
  file 'spec/support/database_cleaner.rb', <<-RUBY
    # frozen_string_literal: true

    RSpec.configure do |config|
      tables_to_truncate = %w[]
      config.before(:suite) do
        DatabaseCleaner.clean_with(:truncation, only: tables_to_truncate)
      end
      config.before(:each) do
        DatabaseCleaner.strategy = DatabaseCleaner::ActiveRecord::Truncation.new(only: tables_to_keep)
      end

      config.before(:each) do
        DatabaseCleaner.start
      end

      config.after(:each) do
        DatabaseCleaner.clean
      end
    end
  RUBY

  # Cria um .env com SECRET_KEY_BASE
  file '.env', <<~ENV
    SECRET_KEY_BASE=#{`rails secret`.strip}
    DATABASE_USERNAME=postgres
    DATABASE_PASSWORD=postgres
    DATABASE_HOST=db
    DATABASE_PORT=5432
    REDIS_URL=redis://redis:6379/1
  ENV

  # Substituir todo o conteúdo do rails_helper.rb
  inject_into_file 'spec/rails_helper.rb', before: /^/ do
    <<~RUBY
      # This file is copied to spec/ when you run 'rails generate rspec:install'
      require 'spec_helper'
      ENV['RAILS_ENV'] ||= 'test'

      require 'database_cleaner/active_record'
      require_relative '../config/environment'
      abort("The Rails environment is running in production mode!") if Rails.env.production?
      require 'rspec/rails'
      require 'support/factory_bot'
      require 'support/database_cleaner'

      require 'simplecov'
      SimpleCov.start 'rails' do
        add_filter 'app/channels/'
        add_filter 'app/views/'
      end

      Shoulda::Matchers.configure do |config|
        config.integrate do |with|
          with.test_framework :rspec
          with.library :rails
        end
      end

    RUBY
  end

  # entrypoint.sh
  file 'entrypoint.sh', <<~CODE
    #!/usr/bin/env bash
    set -e
    echo "Cleaning up old server PIP file..."
    rm -f tmp/pips/server.pid
    exec bundle exec rails s -b 0.0.0.0 -p 3000
  CODE

  # ---- Dockerfile ----
  file 'Dockerfile', <<~DOCKER
    FROM ruby:3.4

    # Instala dependências do sistema
    RUN apt-get update -qq && apt-get install -y \
        build-essential \
        libpq-dev \
        libyaml-dev \
        nodejs \
        postgresql-client \
        libxml2-dev \
        curl \
        && rm -rf /var/lib/apt/lists/*

    WORKDIR /app

    # Copia Gemfile e instala gems
    COPY Gemfile Gemfile.lock ./
    RUN bundle install --jobs 4 --retry 3

    # Copia o restante do código
    COPY . .

    # Ajusta permissões do vendor/bundle

    # Link do log para stdout
    RUN ln -sf /dev/stdout log/development.log

    # Entrypoint
    COPY entrypoint.sh /usr/bin/
    RUN chmod +x /usr/bin/entrypoint.sh
    ENTRYPOINT ["entrypoint.sh"]

    EXPOSE 3000

    CMD ["bundle", "exec", "rails", "s", "-b", "0.0.0.0", "-p", "3000"]

  DOCKER

  # ---- docker-compose-yml ----
  file 'docker-compose.yml', <<~YAML
    version: '3.9'
    services:
      db:
        image: postgres:15
        volumes:
          - postgres_data:/var/lib/postgresql/data
        env_file:
          - .env
        ports:
          - "5432:5432"
      redis:
        image: redis:7-alpine
        ports:
          - "6379:6379"

      web:
        build: .
        command: bash -c "./entrypoint.sh"
        volumes:
          - .:/app
        ports:
          - "3000:3000"
        depends_on:
          - db
        env_file:
          - .env

      sidekiq:
        build: .
        command: bash -c 'bundle exec sidekiq'
        volumes:
          - .:/app
        depends_on:
          - db
          - redis
        env_file:
          - .env

    volumes:
      postgres_data:
  YAML

  # ---- GitHUB Actions (CI) ----
  file '.github/workflows/ci.yml', <<~YAML
    name: CI
    on:
      pull_request:
      push:
        branches: [ main ]

    env:
      APP_NAME: ${{ github.repository_name }}

    jobs:
      scan_ruby:
        runs-on: ubuntu-latest

        steps:
          - name: Checkout code
            uses: actions/checkout@v4

          - name: Set up Ruby
            uses: ruby/setup-ruby@v1
            with:
              ruby-version: .ruby-version
              bundler-cache: true

          - name: Scan for common Rails security vulnerabilities using static analysis
            run: bin/brakeman --no-pager

      lint:
        runs-on: ubuntu-latest
        steps:
          - name: Checkout code
            uses: actions/checkout@v4

          - name: Set up Ruby
            uses: ruby/setup-ruby@v1
            with:
              ruby-version: .ruby-version
              bundler-cache: true

          - name: Lint code for consistent style
            run: bin/rubocop -f github

      test:
        name: Run tests
        runs-on: ubuntu-latest
        services:
          db:
            image: postgres:15
            ports:
              - 5432:5432
            env:
              POSTGRES_USER: postgres
              POSTGRES_PASSWORD: password
              POSTGRES_DB: ${{ github.repository_name}}_test
            options: >-
              --health-cmd pg_isready
              --health-interval 10s
              --health-timeout 5s
              --health-retries 5
        steps:
          - name: Checkout code
            uses: actions/checkout@v4
          - name: Set up Ruby
            uses: ruby/setup-ruby@v1
            with:
              ruby-version: .ruby-version
              bundler-cache: true
          - name: Wait for Postgres to be ready
            run: |
              until pg_isready -h localhost -p 5432 -U postgres; do
                echo "Waiting for Postgres..."
                sleep 2
              done
          - name: Set up database
            env:
              RAILS_ENV: test
              DATABASE_HOST: postgres://postgres:password@localhost:5432/${{ github.repository_name}}_test
            run: |
              bin/rails db:create
              bin/rails db:migrate
          - name: Run tests
            env:
              RAILS_ENV: test
              DATABASE_HOST: postgres://postgres:password@localhost:5432/${{ github.repository_name}}_test
            run: |
              bundle exec rspec
  YAML

  # ---- database.yml ----
  remove_file 'config/database.yml'
  file 'config/database.yml', <<~YAML
    default: &default
      adapter: postgresql
      encoding: unicode
      pool: <%= ENV.fetch("RAILS_MAX_THREADS") { 5 } %>
      username: <%= ENV.fetch('DATABASE_USERNAME', 'postgres') %>
      password: <%= ENV.fetch('DATABASE_PASSWORD', 'postgres') %>
      host: <%= ENV.fetch('DATABASE_HOST', 'db') %>
      port: <%= ENV.fetch('DATABASE_PORT', 5432) %>

    development:
      <<: *default
      database: <%= "\#{Rails.application.class.module_parent_name.underscore}_development" %>

    test:
      <<: *default
      database: <%= "\#{Rails.application.class.module_parent_name.underscore}_test" %>

    production:
      <<: *default
      database: <%= "\#{Rails.application.class.module_parent_name.underscore}_production" %>
  YAML

  # ----- config/sidekiq.yml -----
  file 'config/sidekiq.yml', <<~YAML
    :concurrency: 5
    :queues:
      - default
      - mailers
  YAML

  # ---- config/initailizers/sidekiq.rb ----
  file 'config/initializers/sidekiq.rb', <<~RUBY
    Sidekiq.configure_server do |config|
      config.redis = { url: ENV.fetch("REDIS_URL") { "redis://redis:6379/1" } }
    end
    Sidekiq.configure_client do |config|
      config.redis = { url: ENV.fetch("REDIS_URL") { "redis://redis:6379/1" } }
    end
  RUBY

  #  ---- config/application.rb (ActiveJob Adapter) ----
  application <<~RUBY
    config.active_job.queue_adapter = :sidekiq
  RUBY

  # ---- routes.rb (Sidekiq Web UI) ----
  route <<~RUBY
    require "sidekiq/web"
    mount Sidekiq::Web => '/sidekiq'
  RUBY
end
