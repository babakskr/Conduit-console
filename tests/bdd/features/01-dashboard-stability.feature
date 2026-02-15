Feature: Dashboard stability and refresh behavior
  As an operator
  I want a continuously refreshing dashboard
  So that runtime visibility is reliable

  @critical @dashboard @KR-001
  Scenario: Regression: dashboard loop remains persistent
    Given the dashboard is opened
    When 30 seconds pass without exit input
    Then the dashboard continues refreshing
    And the process does not terminate unexpectedly
