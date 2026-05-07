function result = sl_model_sandbox(modelName, sandboxName, modifyPlan)
% SL_MODEL_SANDBOX Create the sandbox subsystem for Scene 2 modifications.
%
% [P0-2/P0-4 FIX] Removed Goto/From cross-subsystem bridge.
% Now uses direct signal connections to sandbox Inport/Outport ports.
%
% R1: Subsystem interfaces use Inport/Outport (standard contract)
% R2: Goto/From is ONLY for within-subsystem local signals
%
% Automated operations:
%   1. Create empty Subsystem at model top level
%   2. Add Inport/Outport blocks according to modifyPlan
%   3. Connect sandbox input ports directly to existing model source signals
%   4. Outport connections left for AI to complete (sandbox->target)
%
% After creation, the sandbox internal is ready for Scene 1 workflow.

result = struct();
result.status = 'ok';

% ===== [v11.6.6 MANDATORY] Step 0: Clean orphaned/unconnected lines =====
% Scene 2 sandbox auto-connect fails when target ports are occupied by
% orphaned lines from previous sessions. This cleanup runs BEFORE sandbox
% creation — AI cannot bypass because it's hardcoded in the .m function.
try
    all_lines = find_system(modelName, 'FindAll', 'on', 'Type', 'line');
    orphaned_count = 0;
    skipped_count = 0;  % [P1-10 FIX] Track whitelisted lines
    for li = 1:length(all_lines)
        try
            src_h = get_param(all_lines(li), 'SrcBlockHandle');
            dst_h = get_param(all_lines(li), 'DstBlockHandle');
            is_orphan = false;
            
            if src_h <= 0
                % [P1-10 FIX] Check if src_h==0 is from a LEGITIMATE block
                % Ground/Terminator/From blocks and model ports can have src_h==0
                if src_h == 0
                    try
                        % Try to identify the source block by name
                        get_param(all_lines(li), 'SrcBlockName');
                        % Line has identifiable source → legitimate, not orphan
                        is_orphan = false;
                        skipped_count = skipped_count + 1;
                    catch
                        is_orphan = true;  % Cannot identify source → orphan
                    end
                else
                    is_orphan = true;  % Negative handle → orphan
                end
            elseif dst_h <= 0
                % [P1-10 FIX] dst_h==0 can be legitimate (unconnected output)
                if dst_h == 0
                    try
                        get_param(all_lines(li), 'DstBlockName');
                        is_orphan = false;
                        skipped_count = skipped_count + 1;
                    catch
                        is_orphan = true;
                    end
                else
                    is_orphan = true;
                end
            end
            
            if is_orphan
                delete_line(all_lines(li));
                orphaned_count = orphaned_count + 1;
            end
        catch
            % Line handle invalid → definitely orphaned
            try; delete_line(all_lines(li)); orphaned_count = orphaned_count + 1; catch; end
        end
    end
    result.orphanedLinesCleaned = orphaned_count;
    result.orphanedLinesSkipped = skipped_count;  % [P1-10 FIX] Report whitelisted lines
catch ex_clean
    result.orphanedCleanupError = ex_clean.message;
end
% ===== Step 0 end =====

% Step 1: Create the sandbox subsystem
try
    add_block('simulink/Ports & Subsystems/Subsystem', ...
        [modelName '/' sandboxName], 'MakeNameUnique', 'off');
    
    % Remove default In1->Out1 connection inside the new subsystem
    in_port = [modelName '/' sandboxName '/In1'];
    out_port = [modelName '/' sandboxName '/Out1'];
    try
        delete_line([modelName '/' sandboxName], 'In1/1', 'Out1/1');
    catch
        % No default line to delete
    end
catch ex
    result.status = 'error';
    result.error = sprintf('Failed to create sandbox subsystem: %s', ex.message);
    return;
end

result.sandboxPath = [modelName '/' sandboxName];
result.ports = struct();
result.ports.inports = {};
result.ports.outports = {};
result.ports.externalConnections = {};
sandbox_input_port_num = 1;  % Subsystem block's physical input port counter

% ===== Step 2: Add inports + connect from existing model signals =====
% [P0-2 FIX] Direct line from source block -> Subsystem input port
% No Goto/From bridge. Signal enters sandbox through Subsystem port -> Inport.
if isfield(modifyPlan, 'sandboxSubsystem') && ...
   isfield(modifyPlan.sandboxSubsystem, 'inports')
    inports = modifyPlan.sandboxSubsystem.inports;
    for i = 1:length(inports)
        inp = inports{i};
        if isstruct(inp)
            ct = '';
            if isfield(inp, 'connectTo'), ct = inp.connectTo; end
            
            % [v11.6 P0-11] Hard error on empty connectTo
            % Sandbox inports MUST connect to existing model signals.
            % No more silent skipping — enforce physical connection.
            if isempty(ct)
                result.status = 'error';
                result.error = sprintf('Inport "%s" has no connectTo target. All sandbox inports must connect to existing model signals.', inp.name);
                return;
            end
            
            % Get or create Inport block inside sandbox
            if i == 1
                inport_block = in_port;  % reuse default In1
            else
                new_name = [result.sandboxPath '/In' num2str(i)];
                add_block('simulink/Ports & Subsystems/In1', new_name);
                inport_block = new_name;
            end
            
            % [P0-2 FIX] Direct connection: source -> Subsystem input port
            % (NOT Goto/From bridge. The Subsystem block's input port
            %  carries the signal into the Inport block inside.)
            % [v11.6.2 FIX] Use 'Ports' not 'Port' — 'Port' is not a valid param
            port_connected = false;
            connect_error = '';
            if ~isempty(ct)
                ct_path = [modelName '/' ct];
                try
                    % Determine source port number
                    slash_pos = strfind(ct, '/');
                    if ~isempty(slash_pos)
                        % Source is inside a subsystem: Subsys/BlockName
                        source_block = ct(1:slash_pos(1)-1);
                        source_subblock = ct(slash_pos(1)+1:end);
                        % Get parent subsystem's ports to find which outport
                        parent_ports = get_param([modelName '/' source_block], 'Ports');
                        source_outport_count = parent_ports(2);
                        % Try port 1 by default
                        port_num = 1;
                        if source_outport_count >= 1
                            add_line(modelName, ...
                                [source_block '/' num2str(port_num)], ...
                                [sandboxName '/' num2str(sandbox_input_port_num)], ...
                                'autorouting', 'on');
                            port_connected = true;
                        end
                    else
                        % Source is a top-level block
                        % [v11.6.2 FIX] Use 'Ports' (vector) not 'Port' (not a valid param)
                        src_ports = get_param(ct_path, 'Ports');
                        src_outport_count = src_ports(2);  % [in, out, ...]
                        port_num = 1;  % Use first output port by default
                        if src_outport_count >= 1
                            add_line(modelName, ...
                                [ct '/' num2str(port_num)], ...
                                [sandboxName '/' num2str(sandbox_input_port_num)], ...
                                'autorouting', 'on');
                            port_connected = true;
                        end
                    end
                catch ex_conn
                    % [v11.6.2 FIX] Log the actual error instead of silent swallow
                    connect_error = ex_conn.message;
                end
                sandbox_input_port_num = sandbox_input_port_num + 1;
            end
            
            % [P0-4 FIX] Inport block is now connected via Subsystem port.
            % Sandbox internal blocks should connect to Inport output.
            result.ports.inports{end+1} = struct(...
                'block', inport_block, ...
                'connectedFrom', ct, ...
                'connected', port_connected, ...
                'connectError', connect_error, ...
                'subsystemPort', sandbox_input_port_num - 1);
        end
    end
end

% ===== Step 3: Add outports (connection targets for AI to wire later) =====
% [v11.6.2 FIX] Actually auto-connect outports, not just store metadata.
% Previous code only stored connectTo as hint — outports were NEVER connected.
if isfield(modifyPlan, 'sandboxSubsystem') && ...
   isfield(modifyPlan.sandboxSubsystem, 'outports')
    outports = modifyPlan.sandboxSubsystem.outports;
    sandbox_output_port_num = 1;
    for i = 1:length(outports)
        outp = outports{i};
        if isstruct(outp)
            if i == 1
                outport_block = out_port;  % reuse default Out1
            else
                new_name = [result.sandboxPath '/Out' num2str(i)];
                add_block('simulink/Ports & Subsystems/Out1', new_name);
                outport_block = new_name;
            end
            ct = '';
            if isfield(outp, 'connectTo'), ct = outp.connectTo; end
            % [v11.6 P0-11] Hard error on empty outport connectTo
            if isempty(ct)
                result.status = 'error';
                result.error = sprintf('Outport "%s" has no connectTo target. All sandbox outports must connect to existing model targets.', outp.name);
                return;
            end
            
            % [v11.6.2 FIX] Auto-connect outport to destination
            outport_connected = false;
            outport_connect_error = '';
            try
                ct_path = [modelName '/' ct];
                % Get destination block's input port count
                dst_ports = get_param(ct_path, 'Ports');
                dst_inport_count = dst_ports(1);  % [in, out, ...]
                % [v11.6.2 FIX] Find first UNCONNECTED input port on destination
                dst_lh = get_param(ct_path, 'LineHandles');
                target_port = -1;
                for p = 1:dst_inport_count
                    if p <= length(dst_lh.Inport) && dst_lh.Inport(p) == -1
                        target_port = p;
                        break;
                    end
                end
                % [v11.6.5 FIX] If all ports occupied, force-clear orphaned lines
                % from previous sandbox instances that were deleted but left
                % residual connections on disk.
                if target_port < 0
                    cleared_ports = 0;
                    for p = 1:min(dst_inport_count, length(dst_lh.Inport))
                        if dst_lh.Inport(p) > 0
                            try
                                src_handle = get_param(dst_lh.Inport(p), 'SrcBlockHandle');
                                if src_handle <= 0
                                    delete_line(dst_lh.Inport(p));
                                    cleared_ports = cleared_ports + 1;
                                end
                            catch
                                try; delete_line(dst_lh.Inport(p)); cleared_ports = cleared_ports + 1; catch; end
                            end
                        end
                    end
                    if cleared_ports > 0
                        dst_lh = get_param(ct_path, 'LineHandles');
                        for p = 1:dst_inport_count
                            if p <= length(dst_lh.Inport) && dst_lh.Inport(p) == -1
                                target_port = p;
                                break;
                            end
                        end
                    end
                end
                if target_port > 0
                    add_line(modelName, ...
                        [sandboxName '/' num2str(sandbox_output_port_num)], ...
                        [ct '/' num2str(target_port)], ...
                        'autorouting', 'on');
                    outport_connected = true;
                else
                    outport_connect_error = sprintf('Destination %s has no free input ports (%d total, all occupied even after cleanup)', ct, dst_inport_count);
                end
            catch ex_out
                % [v11.6.5 FIX] Log the error instead of silent swallow
                outport_connect_error = ex_out.message;
            end
            
            result.ports.outports{end+1} = struct(...
                'block', outport_block, ...
                'connectTo', ct, ...
                'connected', outport_connected, ...
                'connectError', outport_connect_error, ...
                'connectedToPort', target_port, ...
                'subsystemPort', sandbox_output_port_num);
            sandbox_output_port_num = sandbox_output_port_num + 1;
        end
    end
end

% Step 4: Auto-save
save_system(modelName);
result.sandboxCreated = true;
result.message = sprintf('Sandbox "%s" created with %d inports (%.0f connected), %d outports.', ...
    sandboxName, length(result.ports.inports), ...
    sum(cellfun(@(x) x.connected, result.ports.inports)), ...
    length(result.ports.outports));

% Hint for AI about next steps
result.hint = sprintf([...
    'Sandbox "%s" is ready for Scene 1 workflow. ', ...
    'Use sl_framework_design to design sandbox internal architecture. ', ...
    'Sandbox Inports receive signals from existing model. ', ...
    'After building, connect sandbox Outports to existing model targets via sl_add_line.'], ...
    sandboxName);
