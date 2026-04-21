% Top-level wiring for triple_pendulum model
modelName = 'triple_pendulum';

% Step_Ref -> Pos_Error (+)
sl_add_line_safe(modelName, 'Step_Ref/1', 'Pos_Error/1');
fprintf('1. Step_Ref -> Pos_Error(+)\n');

% Plant/1 (cart position) -> Pos_Error (-)
sl_add_line_safe(modelName, 'Plant/1', 'Pos_Error/2');
fprintf('2. Plant/1 -> Pos_Error(-)\n');

% Plant outputs (8 states) -> State_Mux
for i = 1:8
    sl_add_line_safe(modelName, ['Plant/' num2str(i)], ['State_Mux/' num2str(i)]);
end
fprintf('3. Plant(8) -> State_Mux\n');

% State_Mux -> State_Demux -> Controller
sl_add_line_safe(modelName, 'State_Mux/1', 'State_Demux/1');
fprintf('4. State_Mux -> State_Demux\n');

% State_Demux -> Controller (8 individual lines)
for i = 1:8
    sl_add_line_safe(modelName, ['State_Demux/' num2str(i)], ['Controller/' num2str(i)]);
end
fprintf('5. State_Demux(8) -> Controller(8)\n');

% Controller output -> Force_Scale
sl_add_line_safe(modelName, 'Controller/1', 'Force_Scale/1');
fprintf('6. Controller -> Force_Scale\n');

% Force_Scale -> Force_Limit
sl_add_line_safe(modelName, 'Force_Scale/1', 'Force_Limit/1');
fprintf('7. Force_Scale -> Force_Limit\n');

% Force_Limit -> Plant input
sl_add_line_safe(modelName, 'Force_Limit/1', 'Plant/1');
fprintf('8. Force_Limit -> Plant\n');

% Scope connections
sl_add_line_safe(modelName, 'Plant/1', 'Cart_Scope/1');
sl_add_line_safe(modelName, 'Plant/5', 'Cart_Scope/2');
sl_add_line_safe(modelName, 'Plant/2', 'Angle_Scope/1');
sl_add_line_safe(modelName, 'Plant/3', 'Angle_Scope/2');
sl_add_line_safe(modelName, 'Plant/4', 'Angle_Scope/3');
sl_add_line_safe(modelName, 'Controller/1', 'Control_Scope/1');
fprintf('9. Scope connections OK\n');

% Output port connections
sl_add_line_safe(modelName, 'Plant/1', 'Out_CartPos/1');
sl_add_line_safe(modelName, 'Plant/2', 'Out_Theta1/1');
sl_add_line_safe(modelName, 'Plant/3', 'Out_Theta2/1');
sl_add_line_safe(modelName, 'Plant/4', 'Out_Theta3/1');
fprintf('10. Outport connections OK\n');

fprintf('All top-level wiring done\n');
