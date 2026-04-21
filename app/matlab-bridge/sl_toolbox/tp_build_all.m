% ======================================================================
% Complete rebuild of triple inverted pendulum model
% ======================================================================
modelName = 'triple_pendulum';

% Clean up existing model completely
try; close_system(modelName, 0); catch; end
try; bdclose(modelName); catch; end
warning('off', 'Simulink:Engine:MdlFileShadowing');

% Create fresh model
new_system(modelName);
open_system(modelName);
fprintf('[OK] Fresh model created\n');

% Define parameters (already in workspace from tp_params, but re-ensure)
if ~exist('K', 'var')
    tp_params;
end

%% ===== Build Controller subsystem internals first =====
% We will build subsystems manually for more control

% --- Controller Subsystem ---
add_block('simulink/Ports & Subsystems/SubSystem', [modelName '/Controller']);
% Remove default In1->Out1 line
delete_line([modelName '/Controller'], 'In1/1', 'Out1/1');
% Delete default Out1
delete_block([modelName '/Controller/Out1']);

% Add 8 Inports (rename default In1 to In1 already exists)
% Add Out1
add_block('simulink/Ports & Subsystems/Out1', [modelName '/Controller/Out1']);

% Add K Gain block inside Controller
add_block('simulink/Math Operations/Gain', [modelName '/Controller/K_Gain']);
set_param([modelName '/Controller/K_Gain'], 'Gain', 'K', 'Multiplication', 'Matrix(K*u)');

% Wire: In1(8-dim) -> K_Gain -> Out1
add_line([modelName '/Controller'], 'In1/1', 'K_Gain/1');
add_line([modelName '/Controller'], 'K_Gain/1', 'Out1/1');
fprintf('[OK] Controller subsystem built\n');

% --- Plant Subsystem ---
add_block('simulink/Ports & Subsystems/SubSystem', [modelName '/Plant']);
delete_line([modelName '/Plant'], 'In1/1', 'Out1/1');
delete_block([modelName '/Plant/Out1']);

% Add Out1 through Out8
for i = 1:8
    add_block('simulink/Ports & Subsystems/Out1', [modelName '/Plant/Out' num2str(i)]);
    set_param([modelName '/Plant/Out' num2str(i)], 'Port', num2str(i));
end

% Add State-Space block
add_block('simulink/Continuous/State-Space', [modelName '/Plant/SS_Plant']);
set_param([modelName '/Plant/SS_Plant'], 'A', 'A', 'B', 'B', 'C', 'C', 'D', 'D', ...
    'InitialCondition', 'x0');

% Wire: In1 -> SS_Plant
add_line([modelName '/Plant'], 'In1/1', 'SS_Plant/1');
% Wire: SS_Plant(8 outputs) -> Out1-8
for i = 1:8
    add_line([modelName '/Plant'], ['SS_Plant/' num2str(i)], ['Out' num2str(i) '/1']);
end
fprintf('[OK] Plant subsystem built\n');

%% ===== Add top-level blocks =====
% Step reference
add_block('simulink/Sources/Step', [modelName '/Step_Ref']);
set_param([modelName '/Step_Ref'], 'Time', '2', 'Before', '0', 'After', '0.2');

% Position error Sum
add_block('simulink/Math Operations/Sum', [modelName '/Pos_Error']);
set_param([modelName '/Pos_Error'], 'Inputs', '+-', 'IconShape', 'round');

% Saturation for force limits
add_block('simulink/Discontinuities/Saturation', [modelName '/Force_Limit']);
set_param([modelName '/Force_Limit'], 'UpperLimit', '100', 'LowerLimit', '-100');

% Mux and Demux
add_block('simulink/Signal Routing/Mux', [modelName '/State_Mux']);
set_param([modelName '/State_Mux'], 'Inputs', '8', 'DisplayOption', 'bar');

add_block('simulink/Signal Routing/Demux', [modelName '/State_Demux']);
set_param([modelName '/State_Demux'], 'Outputs', '8', 'DisplayOption', 'bar');

% Scopes
add_block('simulink/Sinks/Scope', [modelName '/Cart_Scope']);
set_param([modelName '/Cart_Scope'], 'NumInputPorts', '2');

add_block('simulink/Sinks/Scope', [modelName '/Angle_Scope']);
set_param([modelName '/Angle_Scope'], 'NumInputPorts', '3');

add_block('simulink/Sinks/Scope', [modelName '/Control_Scope']);

% Output ports
add_block('simulink/Ports & Subsystems/Out1', [modelName '/Out_CartPos']);
set_param([modelName '/Out_CartPos'], 'Port', '1');

add_block('simulink/Ports & Subsystems/Out1', [modelName '/Out_Theta1']);
set_param([modelName '/Out_Theta1'], 'Port', '2');

add_block('simulink/Ports & Subsystems/Out1', [modelName '/Out_Theta2']);
set_param([modelName '/Out_Theta2'], 'Port', '3');

add_block('simulink/Ports & Subsystems/Out1', [modelName '/Out_Theta3']);
set_param([modelName '/Out_Theta3'], 'Port', '4');

fprintf('[OK] Top-level blocks added\n');

%% ===== Top-level wiring =====
% Feedback loop: Step_Ref -> Pos_Error(+) -> Force_Limit -> Plant -> back
% Also: Plant states -> Mux -> Demux -> Controller -> Force_Limit

% Step_Ref -> Pos_Error (+ input 1)
add_line(modelName, 'Step_Ref/1', 'Pos_Error/1');

% Plant/1 (cart pos) -> Pos_Error (- input 2)
add_line(modelName, 'Plant/1', 'Pos_Error/2');

% Pos_Error -> Controller (via Mux for state feedback)
% Actually: we need full state feedback for LQR
% The controller needs all 8 states, not just position error
% So the wiring should be:
%   Plant(8 outputs) -> State_Mux -> Controller
%   Controller output -> Force_Limit -> Plant input
%   Pos_Error output is used for reference tracking (can be added later)

% Plant 8 outputs -> State_Mux
for i = 1:8
    add_line(modelName, ['Plant/' num2str(i)], ['State_Mux/' num2str(i)]);
end

% State_Mux -> Controller (single 8-dim line)
add_line(modelName, 'State_Mux/1', 'Controller/1');

% Controller -> Force_Limit
add_line(modelName, 'Controller/1', 'Force_Limit/1');

% Force_Limit -> Plant input
add_line(modelName, 'Force_Limit/1', 'Plant/1');

% Scope connections
add_line(modelName, 'Plant/1', 'Cart_Scope/1');  % cart position
add_line(modelName, 'Plant/5', 'Cart_Scope/2');  % cart velocity

add_line(modelName, 'Plant/2', 'Angle_Scope/1'); % theta1
add_line(modelName, 'Plant/3', 'Angle_Scope/2'); % theta2
add_line(modelName, 'Plant/4', 'Angle_Scope/3'); % theta3

add_line(modelName, 'Controller/1', 'Control_Scope/1');

% Output ports
add_line(modelName, 'Plant/1', 'Out_CartPos/1');
add_line(modelName, 'Plant/2', 'Out_Theta1/1');
add_line(modelName, 'Plant/3', 'Out_Theta2/1');
add_line(modelName, 'Plant/4', 'Out_Theta3/1');

fprintf('[OK] All wiring done\n');

%% ===== Configure simulation =====
set_param(modelName, 'StopTime', '10');
set_param(modelName, 'Solver', 'ode45');
set_param(modelName, 'RelTol', '1e-6');
fprintf('[OK] Simulation configured\n');

%% ===== Auto-layout =====
try
    Simulink.BlockDiagram.arrangeSystem(modelName, 'FullLayout', 'true');
    fprintf('[OK] Layout arranged\n');
catch
    % Fallback for older MATLAB
    try
        Simulink.BlockDiagram.arrangeSystem(modelName);
        fprintf('[OK] Layout arranged (no FullLayout)\n');
    catch e
        fprintf('[WARN] Layout failed: %s\n', e.message);
    end
end

%% ===== Save =====
save_system(modelName);
fprintf('[OK] Model saved: %s\n', modelName);

%% ===== Verify =====
totalBlocks = length(find_system(modelName, 'SearchDepth', 0));
totalLines = length(get_param(modelName, 'Lines'));
fprintf('\n===== Model Summary =====\n');
fprintf('Total blocks: %d\n', totalBlocks);
fprintf('Total lines: %d\n', totalLines);
fprintf('Model: %s\n', modelName);
fprintf('========================\n');
