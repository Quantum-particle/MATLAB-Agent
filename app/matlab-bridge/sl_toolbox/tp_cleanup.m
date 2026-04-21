% Cleanup and run simulation
modelName = 'triple_pendulum';

% Remove unused blocks: State_Demux, Pos_Error (we use full-state feedback)
sl_delete_safe([modelName '/State_Demux']);
sl_delete_safe([modelName '/Pos_Error']);
fprintf('Cleaned up unused blocks\n');

% Re-save
save_system(modelName);
fprintf('Model saved\n');

% Run simulation
result = sl_sim_run(modelName, 'stopTime', '10');
fprintf('Simulation status: %s\n', result.status);
if strcmp(result.status, 'ok')
    fprintf('Simulation success: %d\n', result.simulation.success);
    fprintf('Elapsed time: %s\n', result.simulation.elapsedTime);
end

% Get results
simResult = sl_sim_results(modelName);
fprintf('Results: %s\n', simResult.message);
