% Fix IC by editing the model before compilation
modelName = 'triple_pendulum';

% Close and reopen to reset compilation state
close_system(modelName, 1);  % save changes
load_system(modelName);

% Set IC using MATLAB set_param
set_param([modelName '/Plant/SS_Plant'], 'InitialCondition', '[0;0.05;0.05;0.05;0;0;0;0]');

% Verify
ic = get_param([modelName '/Plant/SS_Plant'], 'InitialCondition');
fprintf('IC set to: %s\n', ic);

% Also set K matrix explicitly
set_param([modelName '/Controller/K_Gain'], 'Gain', 'K');

% Save
save_system(modelName);
fprintf('Model saved with IC\n');

% Run simulation
tp_params;
result = sl_sim_run(modelName, 'stopTime', '10');
fprintf('Sim success: %d\n', result.simulation.success);

% Read results
tp_results;
