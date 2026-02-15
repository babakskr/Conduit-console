Feature: Docker lifecycle standards
  As a maintainer
  I want docker instance management to follow strict contracts
  So that deployment remains compatible and stable

  @critical @docker @KR-006
  Scenario: Regression: docker run command follows supported pattern
    Given a new docker conduit instance is created
    When the create flow runs
    Then the container uses the official latest image
    And restart policy is unless-stopped
    And unsupported command wrapping is not injected

  @critical @docker @KR-007
  Scenario: Contract: docker flow does not create systemd units
    Given a docker instance lifecycle operation is completed
    When systemd unit directories are inspected
    Then no docker-specific unit file is created
