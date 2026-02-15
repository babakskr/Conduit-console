Feature: Project governance and architecture contracts
  As a maintainer
  I want core architecture and branding rules preserved
  So that behavior stays stable and traceable across changes

  @critical @smoke
  Scenario: Contract: project branding is sourced from project.conf
    Given a script that displays project branding
    When the script starts
    Then project metadata is sourced from project.conf
    And hardcoded branding values are not required for runtime correctness

  @critical @native @docker
  Scenario: Contract: native and docker domains remain separated
    Given the console manages native and docker instances
    When lifecycle operations are executed
    Then native service control uses systemd paths
    And docker lifecycle is controlled by docker runtime only
