@import XCTest;
@import ObjectiveC.runtime;
@import integration_test;

/// Runs the Dart integration test that the application was built with, through the
/// `integration_test` plugin's native runner, as `INTEGRATION_TEST_IOS_RUNNER` does, so that no
/// VM service connection from `flutter test` is needed. Each Dart test becomes one test method.
///
/// Empty unless `BAROMETER_INTEGRATION_TEST` is set (`TEST_RUNNER_BAROMETER_INTEGRATION_TEST=1` for
/// `xcodebuild`): the runner waits until the Dart side reports results, which only an
/// application built from an integration test entry point does, for example after
/// `flutter build ios --config-only --simulator integration_test/barometer_flow_test.dart`.
@interface IntegrationTests : XCTestCase
@end

@implementation IntegrationTests

+ (NSArray<NSInvocation *> *)testInvocations {
  NSMutableArray<NSInvocation *> *invocations = [NSMutableArray array];
  if (NSProcessInfo.processInfo.environment[@"BAROMETER_INTEGRATION_TEST"] == nil) {
    return invocations;
  }
  FLTIntegrationTestRunner *runner = [[FLTIntegrationTestRunner alloc] init];
  [runner testIntegrationTestWithResults:^(SEL selector, BOOL success, NSString *message) {
    IMP check = imp_implementationWithBlock(^(id _self) {
      XCTAssertTrue(success, @"%@", message);
    });
    class_addMethod(self, selector, check, "v@:");
    NSMethodSignature *signature = [self instanceMethodSignatureForSelector:selector];
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    invocation.selector = selector;
    [invocations addObject:invocation];
  }];
  return invocations;
}

@end
