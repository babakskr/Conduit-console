Feature: UI helper integrity and variable safety
  As a maintainer
  I want helper references and defaults to stay valid
  So that strict Bash mode does not crash the console

  @critical @dashboard @KR-002
  Scenario: Regression: all referenced UI helpers exist
    Given the console script is syntactically valid
    When dashboard rendering paths are exercised
    Then referenced UI helper functions are defined

  @critical @dashboard @KR-003
  Scenario: Regression: unbound variables are guarded
    Given strict variable mode is enabled
    When optional or delayed metrics are unavailable
    Then rendering uses safe defaults
    And execution does not fail with unbound variable errors
