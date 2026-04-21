% Debug unconnected ports
modelName = 'triple_pendulum';

% Check top-level port connections
blocks = find_system(modelName, 'SearchDepth', 1);
fprintf('Top-level blocks (%d):\n', length(blocks));
for i = 1:length(blocks)
    bt = get_param(blocks{i}, 'BlockType');
    fprintf('  %s (%s)\n', blocks{i}, bt);
end

% Check lines
lines = get_param(modelName, 'Lines');
fprintf('\nTop-level lines: %d\n', length(lines));

% Check unconnected ports in detail
fprintf('\n=== Checking unconnected ports ===\n');
for i = 1:length(blocks)
    bt = get_param(blocks{i}, 'BlockType');
    if strcmp(bt, 'Inport') || strcmp(bt, 'Outport') || strcmp(bt, 'Scope') || ...
       strcmp(bt, 'SubSystem') || strcmp(bt, 'Mux') || strcmp(bt, 'Demux') || ...
       strcmp(bt, 'Sum') || strcmp(bt, 'Gain') || strcmp(bt, 'Saturation') || ...
       strcmp(bt, 'Step')
        numIn = str2double(get_param(blocks{i}, 'NumInputPorts'));
        numOut = str2double(get_param(blocks{i}, 'NumOutputPorts'));
        if isnan(numIn)
            try; numIn = length(get_param(blocks{i}, 'PortHandles').Inport); catch; numIn = 0; end
        end
        if isnan(numOut)
            try; numOut = length(get_param(blocks{i}, 'PortHandles').Outport); catch; numOut = 0; end
        end
        if numIn > 0 || numOut > 0
            fprintf('  %s: %d in, %d out\n', blocks{i}, numIn, numOut);
        end
    end
end

% Focus: Check if State_Mux output connects properly
fprintf('\n=== State_Mux check ===\n');
try
    muxOut = get_param([modelName '/State_Mux'], 'PortHandles');
    fprintf('Mux output ports: %d\n', length(muxOut.Outport));
    for i = 1:length(muxOut.Outport)
        lines = get(muxOut.Outport(i));
        fprintf('  Outport %d: %d lines connected\n', i, length(lines));
    end
catch e
    fprintf('Error: %s\n', e.message);
end

% Check if Demux input is connected
fprintf('\n=== State_Demux check ===\n');
try
    demuxIn = get_param([modelName '/State_Demux'], 'PortHandles');
    fprintf('Demux input ports: %d\n', length(demuxIn.Inport));
    for i = 1:length(demuxIn.Inport)
        lines = get(demuxIn.Inport(i));
        fprintf('  Inport %d: %d lines connected\n', i, length(lines));
    end
    fprintf('Demux output ports: %d\n', length(demuxOut.Outport));
catch e
    fprintf('Error: %s\n', e.message);
end

% Check Controller subsystem ports
fprintf('\n=== Controller ports check ===\n');
try
    cIn = get_param([modelName '/Controller'], 'PortHandles');
    fprintf('Controller input ports: %d\n', length(cIn.Inport));
    cOut = get_param([modelName '/Controller'], 'PortHandles');
    fprintf('Controller output ports: %d\n', length(cOut.Outport));
catch e
    fprintf('Error: %s\n', e.message);
end

fprintf('\nDebug done\n');
