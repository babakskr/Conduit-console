Feature: Input validation and command safety
  As a security-conscious maintainer
  I want all user inputs validated and safely handled
  So that command injection paths are blocked

  @critical @security @KR-009
  Scenario: Security: invalid instance names are rejected
    Given an operator provides an instance identifier
    When the identifier does not match approved naming rules
    Then the operation is rejected
    And no shell command is executed with unsafe input
