% Complete rebuild using sl_toolbox API
modelName = 'triple_pendulum';
try; close_system(modelName, 0); catch; end
try; bdclose(modelName); catch; end
warning('off', 'Simulink:Engine:MdlFileShadowing');

% Ensure params exist
if ~exist('K', 'var')
    tp_params;
end

% Create fresh model
sl_init;
result = sl_subsystem_create(modelName, '__temp__', 'empty', 'inputPorts', 0, 'outputPorts', 0);
% Actually we need to create the model first
% Use the simulink/create API doesn't work well in .m files
% Let's use new_system directly
new_system(modelName);
open_system(modelName);
fprintf('[OK] Fresh model created\n');

%% Build using sl_toolbox API calls
% Controller subsystem
sl_subsystem_create(modelName, 'Controller', 'empty', 'inputPorts', 1, 'outputPorts', 1);
fprintf('[OK] Controller subsystem\n');

% Plant subsystem
sl_subsystem_create(modelName, 'Plant', 'empty', 'inputPorts', 1, 'outputPorts', 8);
fprintf('[OK] Plant subsystem\n');

% Fill Controller
ctrlPath = [modelName '/Controller'];
sl_add_block_safe(ctrlPath, 'Gain', 'destPath', [ctrlPath '/K_Gain'], ...
    'params', struct('Gain', 'K', 'Multiplication', 'Matrix(K*u)'));
sl_add_line_safe(ctrlPath, 'In1/1', 'K_Gain/1');
sl_add_line_safe(ctrlPath, 'K_Gain/1', 'Out1/1');
fprintf('[OK] Controller filled\n');

% Fill Plant
plantPath = [modelName '/Plant'];
sl_add_block_safe(plantPath, 'State-Space', 'destPath', [plantPath '/SS_Plant'], ...
    'params', struct('A', 'A', 'B', 'B', 'C', 'C', 'D', 'D', ...
    'InitialCondition', 'x0'));
sl_add_line_safe(plantPath, 'In1/1', 'SS_Plant/1');
for i = 1:8
    sl_add_line_safe(plantPath, ['SS_Plant/' num2str(i)], ['Out' num2str(i) '/1']);
end
fprintf('[OK] Plant filled\n');

% Top-level blocks
sl_add_block_safe(modelName, 'Step', 'destPath', [modelName '/Step_Ref'], ...
    'params', struct('Time', '2', 'Before', '0', 'After', '0.2'));

sl_add_block_safe(modelName, 'Add', 'destPath', [modelName '/Pos_Error'], ...
    'params', struct('Inputs', '+-', 'IconShape', 'round'));

sl_add_block_safe(modelName, 'Saturation', 'destPath', [modelName '/Force_Limit'], ...
    'params', struct('UpperLimit', '100', 'LowerLimit', '-100'));

sl_add_block_safe(modelName, 'Mux', 'destPath', [modelName '/State_Mux'], ...
    'params', struct('Inputs', '8', 'DisplayOption', 'bar'));

sl_add_block_safe(modelName, 'Demux', 'destPath', [modelName '/State_Demux'], ...
    'params', struct('Outputs', '8', 'DisplayOption', 'bar'));

sl_add_block_safe(modelName, 'Scope', 'destPath', [modelName '/Cart_Scope'], ...
    'params', struct('NumInputPorts', '2'));

sl_add_block_safe(modelName, 'Scope', 'destPath', [modelName '/Angle_Scope'], ...
    'params', struct('NumInputPorts', '3'));

sl_add_block_safe(modelName, 'Scope', 'destPath', [modelName '/Control_Scope']);

sl_add_block_safe(modelName, 'Out1', 'destPath', [modelName '/Out_CartPos'], ...
    'params', struct('Port', '1'));
sl_add_block_safe(modelName, 'Out1', 'destPath', [modelName '/Out_Theta1'], ...
    'params', struct('Port', '2'));
sl_add_block_safe(modelName, 'Out1', 'destPath', [modelName '/Out_Theta2'], ...
    'params', struct('Port', '3'));
sl_add_block_safe(modelName, 'Out1', 'destPath', [modelName '/Out_Theta3'], ...
    'params', struct('Port', '4'));

fprintf('[OK] Top-level blocks added\n');

% Top-level wiring
sl_add_line_safe(modelName, 'Step_Ref/1', 'Pos_Error/1');
sl_add_line_safe(modelName, 'Plant/1', 'Pos_Error/2');

for i = 1:8
    sl_add_line_safe(modelName, ['Plant/' num2str(i)], ['State_Mux/' num2str(i)]);
end

sl_add_line_safe(modelName, 'State_Mux/1', 'Controller/1');
sl_add_line_safe(modelName, 'Controller/1', 'Force_Limit/1');
sl_add_line_safe(modelName, 'Force_Limit/1', 'Plant/1');

% Scopes
sl_add_line_safe(modelName, 'Plant/1', 'Cart_Scope/1');
sl_add_line_safe(modelName, 'Plant/5', 'Cart_Scope/2');
sl_add_line_safe(modelName, 'Plant/2', 'Angle_Scope/1');
sl_add_line_safe(modelName, 'Plant/3', 'Angle_Scope/2');
sl_add_line_safe(modelName, 'Plant/4', 'Angle_Scope/3');
sl_add_line_safe(modelName, 'Controller/1', 'Control_Scope/1');

% Output ports
sl_add_line_safe(modelName, 'Plant/1', 'Out_CartPos/1');
sl_add_line_safe(modelName, 'Plant/2', 'Out_Theta1/1');
sl_add_line_safe(modelName, 'Plant/3', 'Out_Theta2/1');
sl_add_line_safe(modelName, 'Plant/4', 'Out_Theta3/1');

fprintf('[OK] All wiring done\n');

% Configure simulation
sl_config_set(modelName, struct('StopTime', '10', 'Solver', 'ode45', 'RelTol', '1e-6'));
fprintf('[OK] Simulation configured\n');

% Auto-layout (with safety: save first, verify after)
save_system(modelName);
try
    Simulink.BlockDiagram.arrangeSystem(modelName, 'FullLayout', 'true');
    fprintf('[OK] Layout arranged\n');
catch
    try
        Simulink.BlockDiagram.arrangeSystem(modelName);
        fprintf('[OK] Layout arranged (basic)\n');
    catch e
        fprintf('[WARN] Layout failed: %s\n', e.message);
    end
end
save_system(modelName);
fprintf('[OK] Model saved\n');

% Verify
totalBlocks = length(find_system(modelName, 'SearchDepth', 0));
totalLines = length(get_param(modelName, 'Lines'));
fprintf('===== Model Summary =====\n');
fprintf('Total blocks: %d\n', totalBlocks);
fprintf('Total lines: %d\n', totalLines);
fprintf('Model: %s\n', modelName);
fprintf('=========================\n');
