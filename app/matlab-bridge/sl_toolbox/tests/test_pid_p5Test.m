classdef test_pid_p5Test < sltest.TestCase
    methods (Test)
        function baselineTest(testCase)
            simout = testCase.simulate('test_pid_p5');
            baselineData = load('C:\Users\泰坦\.workbuddy\skills\matlab-agent\app\matlab-bridge\sl_toolbox\tests\baselines\test_pid_p5_baseline.mat');
            testCase.verifySignalsMatch(simout, baselineData.baselineSimOut, ...
                'RelTol', 0.01, 'AbsTol', 1e-06);
        end
    end
    methods (Static)
        function generateBaseline()
            sl_baseline_test('test_pid_p5', 'action', 'regenerate');
        end
    end
end
