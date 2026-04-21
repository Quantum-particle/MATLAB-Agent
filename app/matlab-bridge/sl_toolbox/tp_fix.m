% Fix unconnected ports
modelName = 'triple_pendulum';

% Check existing lines
lines = get_param(modelName, 'Lines');
fprintf('Total top-level lines: %d\n', length(lines));

% List all lines
for i = 1:length(lines)
    if ~isempty(lines(i).DstBlock)
        fprintf('  Line %d: %s/%d -> %s/%d\n', i, ...
            lines(i).SrcBlock, lines(i).SrcPort, ...
            lines(i).DstBlock, lines(i).DstPort);
    end
end

% Fix 1: Remove Force_Scale (redundant, Gain=1)
% Instead, check if Force_Limit -> Plant/1 line exists
fprintf('\nChecking Force_Limit -> Plant connection...\n');
try
    lh = get_param([modelName '/Force_Limit'], 'PortHandles');
    outLines = get(lh.Outport(1));
    fprintf('Force_Limit output has %d lines\n', length(outLines));
    
    lh2 = get_param([modelName '/Plant'], 'PortHandles');
    inLines = get(lh2.Inport(1));
    fprintf('Plant input has %d lines\n', length(inLines));
catch e
    fprintf('Error: %s\n', e.message);
end

% Fix 2: Check Pos_Error output
fprintf('\nChecking Pos_Error output...\n');
try
    lh = get_param([modelName '/Pos_Error'], 'PortHandles');
    outLines = get(lh.Outport(1));
    fprintf('Pos_Error output has %d lines\n', length(outLines));
catch e
    fprintf('Error: %s\n', e.message);
end

% Fix 3: Check State_Mux -> State_Demux -> Controller
fprintf('\nChecking signal chain...\n');
try
    % Mux output
    lh = get_param([modelName '/State_Mux'], 'PortHandles');
    outLines = get(lh.Outport(1));
    fprintf('State_Mux output has %d lines\n', length(outLines));
    
    % Demux input
    lh = get_param([modelName '/State_Demux'], 'PortHandles');
    inLines = get(lh.Inport(1));
    fprintf('State_Demux input has %d lines\n', length(inLines));
    
    % Demux outputs
    for i = 1:min(8, length(lh.Outport))
        try
            outL = get(lh.Outport(i));
            fprintf('  Demux out %d: %d lines\n', i, length(outL));
        catch
            fprintf('  Demux out %d: no lines\n', i);
        end
    end
catch e
    fprintf('Error: %s\n', e.message);
end

fprintf('\nFix check done\n');
