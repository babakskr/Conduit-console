Feature: Docker dashboard performance and data authority
  As an operator
  I want docker metrics to be accurate and fast
  So that dashboard refresh remains responsive

  @critical @docker @KR-004
  Scenario: Regression: docker refresh avoids blocking behavior
    Given multiple docker containers are running
    When one dashboard refresh cycle is executed
    Then docker collection follows bounded work per cycle
    And expensive log reads are cached with TTL

  @critical @docker @KR-005
  Scenario: Contract: docker runtime is the source of truth
    Given local metadata exists for docker instances
    When runtime container state differs from metadata
    Then dashboard status reflects docker runtime state
    And metadata is not treated as runtime authority
