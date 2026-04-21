% Fill subsystem internals for triple_pendulum model
modelName = 'triple_pendulum';

%% Fill Controller subsystem
ctrlPath = [modelName '/Controller'];

% LQR Gain block: K * x -> u
sl_add_block_safe(ctrlPath, 'Gain', 'destPath', [ctrlPath '/K_Gain'], ...
    'params', struct('Gain', 'K', 'Multiplication', 'Matrix(K*u)'));
fprintf('K_Gain OK\n');

% Connect: In1 (8-dim) -> K_Gain -> Out1
sl_add_line_safe(ctrlPath, 'In1/1', 'K_Gain/1');
sl_add_line_safe(ctrlPath, 'K_Gain/1', 'Out1/1');
fprintf('Controller wiring OK\n');

%% Fill Plant subsystem (State-Space)
plantPath = [modelName '/Plant'];

% State-Space block with A, B, C, D from workspace
sl_add_block_safe(plantPath, 'State-Space', 'destPath', [plantPath '/SS_Plant'], ...
    'params', struct('A', 'A', 'B', 'B', 'C', 'C', 'D', 'D', ...
    'InitialCondition', 'x0'));
fprintf('SS_Plant OK\n');

% Connect In1 -> SS_Plant
sl_add_line_safe(plantPath, 'In1/1', 'SS_Plant/1');

% Connect SS_Plant outputs to 8 Outports
for i = 1:8
    sl_add_line_safe(plantPath, ['SS_Plant/' num2str(i)], ['Out' num2str(i) '/1']);
end
fprintf('Plant wiring OK\n');

fprintf('All subsystems filled\n');
