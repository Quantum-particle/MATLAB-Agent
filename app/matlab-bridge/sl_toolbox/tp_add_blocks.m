% Build top-level blocks for triple_pendulum model
modelName = 'triple_pendulum';

% Add Step reference for cart position
sl_add_block_safe(modelName, 'Step', 'destPath', [modelName '/Step_Ref'], ...
    'params', struct('Time', '2', 'Before', '0', 'After', '0.2'));
fprintf('Step_Ref OK\n');

% Add Sum for error (position error)
sl_add_block_safe(modelName, 'Add', 'destPath', [modelName '/Pos_Error'], ...
    'params', struct('Inputs', '+-', 'IconShape', 'round'));
fprintf('Pos_Error OK\n');

% Add Gain for force scaling
sl_add_block_safe(modelName, 'Gain', 'destPath', [modelName '/Force_Scale'], ...
    'params', struct('Gain', '1'));
fprintf('Force_Scale OK\n');

% Add Saturation for force limits
sl_add_block_safe(modelName, 'Saturation', 'destPath', [modelName '/Force_Limit'], ...
    'params', struct('UpperLimit', '100', 'LowerLimit', '-100'));
fprintf('Force_Limit OK\n');

% Add Mux to combine 8 states
sl_add_block_safe(modelName, 'Mux', 'destPath', [modelName '/State_Mux'], ...
    'params', struct('Inputs', '8', 'DisplayOption', 'bar'));
fprintf('State_Mux OK\n');

% Add Demux to split 8 states for Controller
sl_add_block_safe(modelName, 'Demux', 'destPath', [modelName '/State_Demux'], ...
    'params', struct('Outputs', '8', 'DisplayOption', 'bar'));
fprintf('State_Demux OK\n');

% Scopes
sl_add_block_safe(modelName, 'Scope', 'destPath', [modelName '/Cart_Scope'], ...
    'params', struct('NumInputPorts', '4'));
fprintf('Cart_Scope OK\n');

sl_add_block_safe(modelName, 'Scope', 'destPath', [modelName '/Angle_Scope'], ...
    'params', struct('NumInputPorts', '3'));
fprintf('Angle_Scope OK\n');

sl_add_block_safe(modelName, 'Scope', 'destPath', [modelName '/Control_Scope'], ...
    'params', struct('NumInputPorts', '1'));
fprintf('Control_Scope OK\n');

% Output ports
sl_add_block_safe(modelName, 'Out1', 'destPath', [modelName '/Out_CartPos'], ...
    'params', struct('Port', '1'));
sl_add_block_safe(modelName, 'Out1', 'destPath', [modelName '/Out_Theta1'], ...
    'params', struct('Port', '2'));
sl_add_block_safe(modelName, 'Out1', 'destPath', [modelName '/Out_Theta2'], ...
    'params', struct('Port', '3'));
sl_add_block_safe(modelName, 'Out1', 'destPath', [modelName '/Out_Theta3'], ...
    'params', struct('Port', '4'));
fprintf('Outports OK\n');

fprintf('All top-level blocks added\n');
