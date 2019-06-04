$LOAD_PATH.unshift File.expand_path("../../lib", __FILE__)
require "puma/plugin/PumaPluginDogstatsd"

require "minitest/autorun"
