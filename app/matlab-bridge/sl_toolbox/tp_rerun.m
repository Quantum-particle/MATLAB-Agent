% Re-run simulation with proper parameters
sl_init;
tp_params;

% Check that x0 is defined
fprintf('x0 = '); disp(x0);

% Verify SS_Plant has correct initial condition
ic = get_param('triple_pendulum/Plant/SS_Plant', 'InitialCondition');
fprintf('SS_Plant IC: %s\n', ic);

% Re-run simulation
result = sl_sim_run('triple_pendulum', 'stopTime', '10');
fprintf('Sim success: %d, elapsed: %s\n', result.simulation.success, result.simulation.elapsedTime);

% Check results
tp_results;
