"""Behave step-definition stubs for Conduit-console.

These stubs are intentionally lightweight placeholders.
Fill implementation in your BDD runner environment.
"""

from behave import given, when, then


@given("the dashboard is opened")
def step_dashboard_opened(context):
    raise NotImplementedError("Implement dashboard launch precondition")


@when("30 seconds pass without exit input")
def step_wait_30_seconds(context):
    raise NotImplementedError("Implement non-interactive wait/check flow")


@then("the dashboard continues refreshing")
def step_dashboard_refreshes(context):
    raise NotImplementedError("Assert dashboard remains alive and updates")


@given("a new docker conduit instance is created")
def step_new_docker_instance(context):
    raise NotImplementedError("Implement docker instance fixture")


@then("no docker-specific unit file is created")
def step_no_docker_unit(context):
    raise NotImplementedError("Assert no *-docker.service generated")


@then("help output contains Description")
def step_help_has_description(context):
    raise NotImplementedError("Assert help contract section")
