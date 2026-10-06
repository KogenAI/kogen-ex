require_relative "boot"
require "rails"
require "action_controller/railtie"

module TinyRails
  class Application < Rails::Application
    config.load_defaults 8.1
    config.eager_load = false
    config.secret_key_base = "offline-fixture"
    config.hosts.clear
    config.logger = Logger.new(File::NULL)
  end
end
