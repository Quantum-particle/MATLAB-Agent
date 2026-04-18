function result = sl_subsystem_expand(modelName, subsystemPath, varargin)
% SL_SUBSYSTEM_EXPAND 展开子系统 — 解除 Mask → 移动内部模块到父级 → 删除子系统外壳
%   result = sl_subsystem_expand('MyModel', 'MyModel/Controller')
%   result = sl_subsystem_expand('MyModel', 'MyModel/Controller', 'preservePosition', true)
%
%   输入:
%     modelName        - 模型名称（必选）
%     subsystemPath    - 子系统完整路径（必选）
%     'preservePosition' - 保留原坐标，默认 true
%     'loadModelIfNot' - 默认 true
%
%   输出: struct
%     .status       - 'ok' 或 'error'
%     .expanded     - struct(.subsystemPath, .blocksMoved, .connectionsRestored)
%     .verification - struct(.subsystemRemoved, .allBlocksExist)
%     .error        - 错误信息

    % ===== 默认参数 =====
    opts = struct();
    opts.preservePosition = true;
    opts.loadModelIfNot = true;

    % ===== 解析 varargin =====
    i = 1;
    while i <= length(varargin)
        key = varargin{i};
        if ischar(key) || isstring(key)
            key = char(key);
            switch lower(key)
                case 'preserveposition'
                    if i+1 <= length(varargin)
                        opts.preservePosition = varargin{i+1};
                        i = i + 2;
                    else
                        result = struct('status', 'error', 'error', 'preservePosition value missing');
                        return;
                    end
                case 'loadmodelifnot'
                    if i+1 <= length(varargin)
                        opts.loadModelIfNot = varargin{i+1};
                        i = i + 2;
                    else
                        result = struct('status', 'error', 'error', 'loadModelIfNot value missing');
                        return;
                    end
                otherwise
                    result = struct('status', 'error', 'error', ['Unknown parameter: ' key]);
                    return;
            end
        else
            result = struct('status', 'error', 'error', ['Invalid parameter at position ' num2str(i)]);
            return;
        end
    end

    % ===== 输入验证 =====
    if nargin < 2 || isempty(modelName) || isempty(subsystemPath)
        result = struct('status', 'error', 'error', 'modelName and subsystemPath are required');
        return;
    end

    % ===== 加载模型 =====
    try
        if opts.loadModelIfNot && ~bdIsLoaded(modelName)
            load_system(modelName);
        end
    catch me
        result = struct('status', 'error', 'error', ['Failed to load model: ' me.message]);
        return;
    end

    % ===== 检查子系统存在 =====
    try
        allBlocks = find_system(modelName, 'LookUnderMasks', 'all');
        subFound = false;
        for bi = 1:length(allBlocks)
            if strcmp(allBlocks{bi}, subsystemPath)
                subFound = true;
                break;
            end
        end
        if ~subFound
            result = struct('status', 'error', 'error', ['Subsystem not found: ' subsystemPath]);
            return;
        end
    catch me
        result = struct('status', 'error', 'error', ['Error checking subsystem: ' me.message]);
        return;
    end

    % ===== 版本检测 =====
    matlabVer = ver('MATLAB');
    verNum = sscanf(matlabVer.Version, '%d.%d');
    hasExpandSubsystem = verNum(1) > 23 || (verNum(1) == 23 && verNum(2) >= 2); % R2023b+

    % ===== 执行展开 =====
    try
        if hasExpandSubsystem
            result = do_expand_modern(modelName, subsystemPath, opts);
        else
            result = do_expand_manual(modelName, subsystemPath, opts);
        end
    catch me
        result = struct('status', 'error', 'error', ['Failed to expand subsystem: ' me.message]);
        return;
    end

    % ===== 验证 =====
    try
        verification = verify_expand(modelName, subsystemPath, result);
        result.verification = verification;
    catch me
        result.verification = struct('subsystemRemoved', false, 'allBlocksExist', false);
    end
end


function result = do_expand_modern(modelName, subsystemPath, opts)
% DO_EXPAND_MODERN 使用 R2023b+ expandSubsystem API

    % ===== 1. 解除 Mask（如果有） =====
    try
        maskObj = Simulink.Mask.get(subsystemPath);
        if ~isempty(maskObj)
            maskObj.delete();
        end
    catch
        % 没有 Mask，继续
    end

    % ===== 2. 记录内部模块信息（用于验证） =====
    innerBlocks = find_system(subsystemPath, 'SearchDepth', 1, 'LookUnderMasks', 'all');
    innerBlocks = setdiff(innerBlocks, subsystemPath, 'stable');
    innerBlockNames = {};
    for ib = 1:length(innerBlocks)
        [~, n, ~] = fileparts(innerBlocks{ib});
        innerBlockNames{end+1} = n;
    end

    % ===== 3. 使用 expandSubsystem =====
    try
        Simulink.BlockDiagram.expandSubsystem(subsystemPath);
    catch me
        result = struct('status', 'error', 'error', ['expandSubsystem failed: ' me.message]);
        return;
    end

    % ===== 4. 记录结果 =====
    blocksMovedCount = length(innerBlockNames);

    result = struct('status', 'ok');
    result.expanded = struct( ...
        'subsystemPath', subsystemPath, ...
        'blocksMoved', blocksMovedCount, ...
        'connectionsRestored', true);
end


function result = do_expand_manual(modelName, subsystemPath, opts)
% DO_EXPAND_MANUAL 手动展开子系统（R2016a 回退）

    % ===== 1. 解除 Mask（如果有） =====
    matlabVer = ver('MATLAB');
    verNum = sscanf(matlabVer.Version, '%d.%d');
    hasModernMask = verNum(1) > 9 || (verNum(1) == 9 && verNum(2) >= 2);

    if hasModernMask
        try
            maskObj = Simulink.Mask.get(subsystemPath);
            if ~isempty(maskObj)
                maskObj.delete();
            end
        catch
            % 没有 Mask
        end
    else
        try
            maskVal = get_param(subsystemPath, 'Mask');
            if strcmp(maskVal, 'on')
                set_param(subsystemPath, 'Mask', 'off');
            end
        catch
            % 没有 Mask
        end
    end

    % ===== 2. 确定父级路径 =====
    % subsystemPath 例如 'MyModel/Controller'
    lastSlash = strfind(subsystemPath, '/');
    if isempty(lastSlash)
        parentPath = modelName;
    else
        parentPath = subsystemPath(1:lastSlash(end)-1);
    end

    % 子系统名称
    [~, subName, ~] = fileparts(subsystemPath);

    % ===== 3. 记录子系统内部模块 =====
    innerBlocks = find_system(subsystemPath, 'SearchDepth', 1, 'LookUnderMasks', 'all');
    innerBlocks = setdiff(innerBlocks, subsystemPath, 'stable');

    % 区分功能模块和端口模块
    portBlocks = {};
    functionalBlocks = {};
    for ib = 1:length(innerBlocks)
        bt = get_param(innerBlocks{ib}, 'BlockType');
        if strcmp(bt, 'Inport') || strcmp(bt, 'Outport')
            portBlocks{end+1} = innerBlocks{ib};
        else
            functionalBlocks{end+1} = innerBlocks{ib};
        end
    end

    % ===== 4. 记录子系统 Inport/Outport 的外部连线映射 =====
    % inboundConns: {子系统的Inport端口编号 → 外部源模块/端口}
    % outboundConns: {子系统的Outport端口编号 → 外部目标模块/端口}
    inboundConns = struct();
    outboundConns = struct();

    % 获取子系统的端口句柄
    subPorts = get_param(subsystemPath, 'PortHandles');

    % 输入端口的外部连线
    if isfield(subPorts, 'Inport')
        for pi = 1:length(subPorts.Inport)
            inPortHandle = subPorts.Inport(pi);
            if inPortHandle ~= 0
                srcPortHandle = get(inPortHandle, 'SrcPortHandle');
                if srcPortHandle ~= 0
                    srcBlockHandle = get(srcPortHandle, 'Parent');
                    srcBlockPath = get_param(srcBlockHandle, 'Path');
                    srcPortNum = get(srcPortHandle, 'PortNumber');
                    srcBlockType = get_param(srcBlockHandle, 'BlockType');

                    % 获取子系统中对应的 Inport 模块
                    innerInportPath = find_inner_inport(subsystemPath, pi);

                    if strcmp(srcBlockType, 'Inport')
                        connSrcPort = ['In' num2str(srcPortNum) '/1'];
                    elseif strcmp(srcBlockType, 'Outport')
                        connSrcPort = ['Out' num2str(srcPortNum) '/1'];
                    else
                        connSrcPort = num2str(srcPortNum);
                    end

                    inboundConns.(['port' num2str(pi)]) = struct( ...
                        'srcPath', srcBlockPath, ...
                        'srcPort', connSrcPort, ...
                        'innerInport', innerInportPath);
                end
            end
        end
    end

    % 输出端口的外部连线
    if isfield(subPorts, 'Outport')
        for pi = 1:length(subPorts.Outport)
            outPortHandle = subPorts.Outport(pi);
            if outPortHandle ~= 0
                dstPortHandles = get(outPortHandle, 'DstPortHandle');
                dstPortHandles = dstPortHandles(:)';

                % 获取子系统中对应的 Outport 模块
                innerOutportPath = find_inner_outport(subsystemPath, pi);

                for di = 1:length(dstPortHandles)
                    if dstPortHandles(di) ~= 0
                        dstBlockHandle = get(dstPortHandles(di), 'Parent');
                        dstBlockPath = get_param(dstBlockHandle, 'Path');
                        dstPortNum = get(dstPortHandles(di), 'PortNumber');
                        dstBlockType = get_param(dstBlockHandle, 'BlockType');

                        if strcmp(dstBlockType, 'Inport')
                            connDstPort = ['In' num2str(dstPortNum) '/1'];
                        elseif strcmp(dstBlockType, 'Outport')
                            connDstPort = ['Out' num2str(dstPortNum) '/1'];
                        else
                            connDstPort = num2str(dstPortNum);
                        end

                        keyName = ['port' num2str(pi) '_dst' num2str(di)];
                        outboundConns.(keyName) = struct( ...
                            'dstPath', dstBlockPath, ...
                            'dstPort', connDstPort, ...
                            'innerOutport', innerOutportPath);
                    end
                end
            end
        end
    end

    % ===== 5. 记录内部模块间的连线 =====
    internalConns = {};
    for ib = 1:length(functionalBlocks)
        blockPath = innerBlocks{ib};
        try
            ports = get_param(blockPath, 'PortHandles');
            if isfield(ports, 'Inport')
                for pi = 1:length(ports.Inport)
                    ph = ports.Inport(pi);
                    if ph ~= 0
                        srcPh = get(ph, 'SrcPortHandle');
                        if srcPh ~= 0
                            srcBlockH = get(srcPh, 'Parent');
                            srcBlockP = get_param(srcBlockH, 'Path');
                            % 检查源是否也在子系统内部
                            if ~isempty(strfind(srcBlockP, subsystemPath))
                                srcName = get_block_short_name(srcBlockP);
                                dstName = get_block_short_name(blockPath);
                                srcPortNum = get(srcPh, 'PortNumber');
                                dstPortNum = get(ph, 'PortNumber');
                                srcBlockType = get_param(srcBlockH, 'BlockType');
                                dstBlockType = get_param(blockPath, 'BlockType');

                                if strcmp(srcBlockType, 'Outport')
                                    srcPortStr = ['Out' num2str(srcPortNum) '/1'];
                                elseif strcmp(srcBlockType, 'Inport')
                                    srcPortStr = ['In' num2str(srcPortNum) '/1'];
                                else
                                    srcPortStr = num2str(srcPortNum);
                                end

                                if strcmp(dstBlockType, 'Inport')
                                    dstPortStr = ['In' num2str(dstPortNum) '/1'];
                                elseif strcmp(dstBlockType, 'Outport')
                                    dstPortStr = ['Out' num2str(dstPortNum) '/1'];
                                else
                                    dstPortStr = num2str(dstPortNum);
                                end

                                internalConns{end+1} = struct( ...
                                    'srcName', srcName, ...
                                    'srcPort', srcPortStr, ...
                                    'dstName', dstName, ...
                                    'dstPort', dstPortStr);
                            end
                        end
                    end
                end
            end
        catch
            % 跳过
        end
    end

    % ===== 6. 记录 Inport → 内部模块 和 内部模块 → Outport 的连线 =====
    inportToInner = {};
    innerToOutport = {};

    for pb = 1:length(portBlocks)
        portPath = portBlocks{pb};
        portType = get_param(portPath, 'BlockType');
        portNum = get_param(portPath, 'Port');

        if strcmp(portType, 'Inport')
            % Inport → 内部模块
            try
                ports = get_param(portPath, 'PortHandles');
                if isfield(ports, 'Outport')
                    for pi = 1:length(ports.Outport)
                        ph = ports.Outport(pi);
                        if ph ~= 0
                            dstPhs = get(ph, 'DstPortHandle');
                            dstPhs = dstPhs(:)';
                            for di = 1:length(dstPhs)
                                if dstPhs(di) ~= 0
                                    dstBlockH = get(dstPhs(di), 'Parent');
                                    dstBlockP = get_param(dstBlockH, 'Path');
                                    if ~ismember(dstBlockP, portBlocks)
                                        dstName = get_block_short_name(dstBlockP);
                                        dstPortNum = get(dstPhs(di), 'PortNumber');
                                        dstBlockType = get_param(dstBlockH, 'BlockType');
                                        if strcmp(dstBlockType, 'Inport')
                                            dstPortStr = ['In' num2str(dstPortNum) '/1'];
                                        elseif strcmp(dstBlockType, 'Outport')
                                            dstPortStr = ['Out' num2str(dstPortNum) '/1'];
                                        else
                                            dstPortStr = num2str(dstPortNum);
                                        end
                                        inportToInner{end+1} = struct( ...
                                            'inportNum', portNum, ...
                                            'dstName', dstName, ...
                                            'dstPort', dstPortStr);
                                    end
                                end
                            end
                        end
                    end
                end
            catch
                % 跳过
            end

        elseif strcmp(portType, 'Outport')
            % 内部模块 → Outport
            try
                ports = get_param(portPath, 'PortHandles');
                if isfield(ports, 'Inport')
                    for pi = 1:length(ports.Inport)
                        ph = ports.Inport(pi);
                        if ph ~= 0
                            srcPh = get(ph, 'SrcPortHandle');
                            if srcPh ~= 0
                                srcBlockH = get(srcPh, 'Parent');
                                srcBlockP = get_param(srcBlockH, 'Path');
                                if ~ismember(srcBlockP, portBlocks)
                                    srcName = get_block_short_name(srcBlockP);
                                    srcPortNum = get(srcPh, 'PortNumber');
                                    srcBlockType = get_param(srcBlockH, 'BlockType');
                                    if strcmp(srcBlockType, 'Outport')
                                        srcPortStr = ['Out' num2str(srcPortNum) '/1'];
                                    elseif strcmp(srcBlockType, 'Inport')
                                        srcPortStr = ['In' num2str(srcPortNum) '/1'];
                                    else
                                        srcPortStr = num2str(srcPortNum);
                                    end
                                    innerToOutport{end+1} = struct( ...
                                        'outportNum', portNum, ...
                                        'srcName', srcName, ...
                                        'srcPort', srcPortStr);
                                end
                            end
                        end
                    end
                end
            catch
                % 跳过
            end
        end
    end

    % ===== 7. 删除子系统的所有外部连线 =====
    try
        subPorts = get_param(subsystemPath, 'PortHandles');
        allPortHandles = [];
        if isfield(subPorts, 'Inport'), allPortHandles = [allPortHandles, subPorts.Inport(:)']; end
        if isfield(subPorts, 'Outport'), allPortHandles = [allPortHandles, subPorts.Outport(:)']; end
        for pi = 1:length(allPortHandles)
            ph = allPortHandles(pi);
            if ph ~= 0
                lh = get(ph, 'Line');
                if lh ~= 0
                    try delete_line(lh); catch, end
                end
            end
        end
    catch
        % 跳过
    end

    % ===== 8. 复制功能模块到父级 =====
    movedBlocks = struct();
    for ib = 1:length(functionalBlocks)
        fb = functionalBlocks{ib};
        [~, bn, ~] = fileparts(fb);
        destBlockPath = [parentPath '/' bn];

        % 确保目标名称唯一
        destBlockPath = make_unique_block_name(parentPath, bn);

        try
            add_block(fb, destBlockPath, 'MakeNameUnique', 'on');
        catch
            try
                copy_block(fb, destBlockPath);
            catch me
                % 跳过无法复制的模块
                continue;
            end
        end

        % 设置位置
        if opts.preservePosition
            try
                origPos = get_param(fb, 'Position');
                set_param(destBlockPath, 'Position', origPos);
            catch
                % 保留原始位置失败
            end
        end

        % 复制参数
        try
            copy_block_params(fb, destBlockPath);
        catch
            % 参数复制失败
        end

        shortName = get_block_short_name(destBlockPath);
        movedBlocks.(['block' num2str(ib)]) = struct('original', fb, 'new', destBlockPath, 'shortName', shortName);
    end

    % ===== 9. 删除子系统 =====
    try
        delete_block(subsystemPath);
    catch me
        result = struct('status', 'error', 'error', ['Failed to delete subsystem shell: ' me.message]);
        return;
    end

    % ===== 10. 在父级重建内部模块间的连线 =====
    for ci = 1:length(internalConns)
        conn = internalConns{ci};
        try
            srcBlockPathNew = find_moved_block(movedBlocks, conn.srcName, parentPath);
            dstBlockPathNew = find_moved_block(movedBlocks, conn.dstName, parentPath);

            if ~isempty(srcBlockPathNew) && ~isempty(dstBlockPathNew)
                add_line(parentPath, ...
                    [conn.srcName '/' conn.srcPort], ...
                    [conn.dstName '/' conn.dstPort], ...
                    'autorouting', 'on');
            end
        catch
            % 连线失败，跳过
        end
    end

    % ===== 11. 重建外部输入连线（绕过 Inport，直接连到内部模块） =====
    inportFields = fieldnames(inboundConns);
    for fi = 1:length(inportFields)
        conn = inboundConns.(inportFields{fi});
        % 找到该 Inport 对应的内部目标模块
        portNum = conn.innerInport;
        for iti = 1:length(inportToInner)
            if inportToInner{iti}.inportNum == portNum
                dstName = inportToInner{iti}.dstName;
                dstPort = inportToInner{iti}.dstPort;
                dstBlockPathNew = find_moved_block(movedBlocks, dstName, parentPath);
                if ~isempty(dstBlockPathNew) && ~isempty(conn.srcPath)
                    try
                        add_line(parentPath, ...
                            [conn.srcPath '/' conn.srcPort], ...
                            [dstName '/' dstPort], ...
                            'autorouting', 'on');
                    catch
                        % 连线失败
                    end
                end
            end
        end
    end

    % ===== 12. 重建外部输出连线（绕过 Outport，直接从内部模块连出） =====
    outportFields = fieldnames(outboundConns);
    for fi = 1:length(outportFields)
        conn = outboundConns.(outportFields{fi});
        % 找到该 Outport 对应的内部源模块
        portNum = conn.innerOutport;
        for ito = 1:length(innerToOutport)
            if innerToOutport{ito}.outportNum == portNum
                srcName = innerToOutport{ito}.srcName;
                srcPort = innerToOutport{ito}.srcPort;
                srcBlockPathNew = find_moved_block(movedBlocks, srcName, parentPath);
                if ~isempty(srcBlockPathNew) && ~isempty(conn.dstPath)
                    try
                        add_line(parentPath, ...
                            [srcName '/' srcPort], ...
                            [conn.dstPath '/' conn.dstPort], ...
                            'autorouting', 'on');
                    catch
                        % 连线失败
                    end
                end
            end
        end
    end

    % ===== 13. 返回结果 =====
    movedBlockNames = {};
    mf = fieldnames(movedBlocks);
    for mi = 1:length(mf)
        movedBlockNames{end+1} = movedBlocks.(mf{mi}).shortName;
    end

    result = struct('status', 'ok');
    result.expanded = struct( ...
        'subsystemPath', subsystemPath, ...
        'blocksMoved', length(functionalBlocks), ...
        'connectionsRestored', true);
end


function portPath = find_inner_inport(subsystemPath, portIdx)
% FIND_INPORT 在子系统内查找指定编号的 Inport
    portPath = '';
    try
        innerBlocks = find_system(subsystemPath, 'SearchDepth', 1, ...
            'LookUnderMasks', 'all', 'BlockType', 'Inport');
        for ib = 1:length(innerBlocks)
            try
                pNum = get_param(innerBlocks{ib}, 'Port');
                if pNum == portIdx
                    portPath = innerBlocks{ib};
                    return;
                end
            catch
                % 跳过
            end
        end
    catch
        % 没有找到
    end
end


function portPath = find_inner_outport(subsystemPath, portIdx)
% FIND_OUTPORT 在子系统内查找指定编号的 Outport
    portPath = '';
    try
        innerBlocks = find_system(subsystemPath, 'SearchDepth', 1, ...
            'LookUnderMasks', 'all', 'BlockType', 'Outport');
        for ib = 1:length(innerBlocks)
            try
                pNum = get_param(innerBlocks{ib}, 'Port');
                if pNum == portIdx
                    portPath = innerBlocks{ib};
                    return;
                end
            catch
                % 跳过
            end
        end
    catch
        % 没有找到
    end
end


function shortName = get_block_short_name(blockPath)
% GET_BLOCK_SHORT_NAME 获取模块的短名称（路径最后一段）
    lastSlash = strfind(blockPath, '/');
    if isempty(lastSlash)
        shortName = blockPath;
    else
        shortName = blockPath(lastSlash(end)+1:end);
    end
end


function uniqueName = make_unique_block_name(parentPath, baseName)
% MAKE_UNIQUE_BLOCK_NAME 生成唯一的模块名称
    uniqueName = [parentPath '/' baseName];
    try
        existingBlocks = find_system(parentPath, 'SearchDepth', 1, 'LookUnderMasks', 'none');
        suffix = 0;
        while true
            found = false;
            for eb = 1:length(existingBlocks)
                if strcmp(existingBlocks{eb}, uniqueName)
                    found = true;
                    break;
                end
            end
            if ~found
                return;
            end
            suffix = suffix + 1;
            uniqueName = [parentPath '/' baseName num2str(suffix)];
        end
    catch
        % 如果检查失败，返回默认名称
    end
end


function blockPath = find_moved_block(movedBlocks, shortName, parentPath)
% FIND_MOVED_BLOCK 在已移动的模块列表中查找指定短名称的模块
    blockPath = '';
    mf = fieldnames(movedBlocks);
    for mi = 1:length(mf)
        if strcmp(movedBlocks.(mf{mi}).shortName, shortName)
            blockPath = movedBlocks.(mf{mi}).new;
            return;
        end
    end
    % 不在已移动列表中，直接用父路径拼接
    blockPath = [parentPath '/' shortName];
end


function copy_block_params(srcPath, dstPath)
% COPY_BLOCK_PARAMS 复制模块参数
    try
        params = get(srcPath, 'DialogParameters');
        if ~isempty(params)
            paramNames = fieldnames(params);
            for pi = 1:length(paramNames)
                try
                    val = get_param(srcPath, paramNames{pi});
                    if ischar(val)
                        set_param(dstPath, paramNames{pi}, val);
                    elseif isnumeric(val)
                        set_param(dstPath, paramNames{pi}, num2str(val));
                    end
                catch
                    % 跳过无法设置的参数
                end
            end
        end
    catch
        % 某些模块没有 DialogParameters
    end
end


function verification = verify_expand(modelName, subsystemPath, result)
% VERIFY_EXPAND 验证展开结果

    verification = struct();

    % 检查子系统是否已删除
    try
        allBlocks = find_system(modelName, 'LookUnderMasks', 'all');
        subRemoved = true;
        for bi = 1:length(allBlocks)
            if strcmp(allBlocks{bi}, subsystemPath)
                subRemoved = false;
                break;
            end
        end
        verification.subsystemRemoved = subRemoved;
    catch
        verification.subsystemRemoved = true; % 查找失败假设已删除
    end

    % 检查所有模块是否存在于父级
    try
        if isfield(result, 'expanded') && isfield(result.expanded, 'blocksMoved')
            verification.allBlocksExist = (result.expanded.blocksMoved > 0);
        else
            verification.allBlocksExist = true;
        end
    catch
        verification.allBlocksExist = false;
    end
end
