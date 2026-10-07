# Synthetic app contract. Never used as a runtime default.
module ReleaseConfig
  APP_NAME = "FixtureApp"
  REPOSITORY = "qtmleap/FixtureApp"
  WORKFLOW = ".github/workflows/testflight.yaml"
  VERIFIED_SHA_ENV = "FIXTURE_VERIFIED_SHA"
  VERIFIED_PR_ENV = "FIXTURE_VERIFIED_PR"
  APP_IDENTIFIER = "example.fixture"
  APP_TARGET = APP_NAME
  PROJECT = "FixtureApp.xcodeproj"
  SCHEME = APP_NAME
  TEAM_ID = "ABCDEFGHIJ"
  TARGETS = { APP_NAME => APP_IDENTIFIER }.freeze
  EXTENSION_IDENTIFIERS = [].freeze
  EXTRA_SECRETS = [].freeze
  SECRET_FILES = {}.freeze
  SIBLINGS = {}.freeze
  MINIMUM_BUILD = 100
  MATCH_GIT_URL = "https://github.com/qtmleap/match.git"
  UPLOAD = {}.freeze
  REQUIRED = { ".github/workflows/ci.yaml" => ["Policy"] }.freeze
end
