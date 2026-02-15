Feature: Release protocol and upstream change awareness
  As a maintainer
  I want predictable release operations and upstream monitoring
  So that breaking upstream changes are detected early

  @critical @release
  Scenario: Ops: release workflow is executed via git_op utility
    Given repository changes are ready for release
    When release is performed
    Then git_op utility is used as the protocol command

  @critical @docker @KR-010
  Scenario: Contract: upstream changes are tracked on a schedule
    Given upstream conduit runtime may change flags or output
    When scheduled checks run
    Then maintainers are notified about new upstream releases
    And parser compatibility can be reviewed proactively
