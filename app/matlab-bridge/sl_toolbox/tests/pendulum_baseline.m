classdef pendulum_baseline < sltest.TestCase
    methods (Test)
        function baselineTest(testCase)
            simout = testCase.simulate('inv_pendulum_test');
            baselineData = load('C:\Users\泰坦\.workbuddy\skills\matlab-agent\app\matlab-bridge\sl_toolbox\tests\baselines\inv_pendulum_test_baseline.mat');
            testCase.verifySignalsMatch(simout, baselineData.baselineSimOut, ...
                'RelTol', 0.01, 'AbsTol', 1e-06);
        end
    end
    methods (Static)
        function generateBaseline()
            sl_baseline_test('inv_pendulum_test', 'action', 'regenerate');
        end
    end
end
