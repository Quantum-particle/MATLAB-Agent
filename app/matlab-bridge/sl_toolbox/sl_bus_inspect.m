function result = sl_bus_inspect(busName, varargin)
% SL_BUS_INSPECT 检查总线结构 — 返回字段/类型/维度/复杂度 + 嵌套 Bus + 使用方查找
%   result = sl_bus_inspect('MyBus')
%   result = sl_bus_inspect('MyBus', 'source', 'workspace')
%   result = sl_bus_inspect('MyBus', 'source', 'dictionary', 'dictionaryPath', 'path.sldd')
%
%   版本策略: 优先 R2022b+，R2016a 回退兼容
%
%   输入:
%     busName    - 总线对象名称（必选）
%     'source'   - 查找来源: 'workspace'(默认)/'dictionary'/'model'
%     'dictionaryPath' - 数据字典路径（source='dictionary' 时必填）
%     'findUsage' - 是否查找使用方模块，默认 true
%     'recursive' - 是否递归解析嵌套 Bus，默认 true
%
%   输出: struct
%     .status   - 'ok' 或 'error'
%     .bus      - struct(.name, .elementCount, .elements, .usedByBlocks, .nestedBuses)
%     .message  - 人类可读的总结信息
%     .error    - 错误信息（仅 status='error' 时）

    % ===== 解析参数 =====
    source = 'workspace';
    dictionaryPath = '';
    findUsage = true;
    recursive = true;

    idx = 1;
    while idx <= length(varargin)
        if ischar(varargin{idx}) && idx < length(varargin)
            key = varargin{idx};
            val = varargin{idx+1};
            switch lower(key)
                case 'source'
                    source = val;
                case 'dictionarypath'
                    dictionaryPath = val;
                case 'findusage'
                    findUsage = val;
                case 'recursive'
                    recursive = val;
            end
        end
        idx = idx + 2;
    end

    result = struct('status', 'ok', 'bus', struct(), ...
        'message', '', 'error', '');

    % ===== 获取 Bus 对象 =====
    bus = [];
    switch lower(source)
        case 'workspace'
            try
                bus = evalin('base', busName);
            catch ME
                result.status = 'error';
                result.error = ['Bus object ''' busName ''' not found in workspace: ' ME.message];
                result.message = result.error;
                return;
            end

        case 'dictionary'
            if isempty(dictionaryPath)
                result.status = 'error';
                result.error = 'dictionaryPath is required when source=''dictionary''';
                result.message = result.error;
                return;
            end
            try
                dictObj = Simulink.data.dictionary.open(dictionaryPath);
                section = dictObj.getSection('DesignData');
                entry = section.getEntry(busName);
                bus = entry.getValue();
            catch ME
                result.status = 'error';
                result.error = ['Bus object ''' busName ''' not found in dictionary: ' ME.message];
                result.message = result.error;
                return;
            end

        otherwise
            result.status = 'error';
            result.error = ['Unknown source: ' source];
            result.message = result.error;
            return;
    end

    % ===== 验证是 Bus 对象 =====
    if ~isa(bus, 'Simulink.Bus')
        result.status = 'error';
        result.error = ['''' busName ''' is not a Simulink.Bus object (actual type: ' class(bus) ')'];
        result.message = result.error;
        return;
    end

    % ===== 解析 Elements =====
    elements = bus.Elements;
    nElements = length(elements);
    nestedBuses = {};
    elemInfos = cell(1, nElements);

    for ei = 1:nElements
        el = elements(ei);
        info = struct();
        info.name = el.Name;

        try
            info.dataType = el.DataType;
        catch
            info.dataType = 'unknown';
        end

        try
            if isnumeric(el.Dimensions)
                info.dimensions = num2str(el.Dimensions);
            else
                info.dimensions = el.Dimensions;
            end
        catch
            info.dimensions = '1';
        end

        try
            info.complexity = el.Complexity;
        catch
            info.complexity = 'real';
        end

        % 检测嵌套 Bus
        try
            if ~isempty(info.dataType) && length(info.dataType) > 4 && ...
               strcmpi(info.dataType(1:4), 'Bus:')
                nestedBusName = strtrim(info.dataType(5:end));
                info.isNestedBus = true;
                info.nestedBusName = nestedBusName;
                nestedBuses{end+1} = nestedBusName; %#ok<AGROW>
            else
                info.isNestedBus = false;
                info.nestedBusName = '';
            end
        catch
            info.isNestedBus = false;
            info.nestedBusName = '';
        end

        elemInfos{ei} = info;
    end

    % ===== 查找使用方模块 =====
    usedByBlocks = {};
    if findUsage
        usedByBlocks = find_bus_usage(busName);
    end

    % ===== 递归解析嵌套 Bus =====
    nestedBusDetails = struct();
    if recursive && ~isempty(nestedBuses)
        for ni = 1:length(nestedBuses)
            nbName = nestedBuses{ni};
            try
                nestedBus = evalin('base', nbName);
                if isa(nestedBus, 'Simulink.Bus')
                    nestedDetail = struct();
                    nestedDetail.name = nbName;
                    nestedDetail.elementCount = length(nestedBus.Elements);
                    neNames = {};
                    for nei = 1:length(nestedBus.Elements)
                        neNames{end+1} = nestedBus.Elements(nei).Name; %#ok<AGROW>
                    end
                    nestedDetail.elementNames = neNames;
                    nestedBusDetails.(nbName) = nestedDetail;
                end
            catch
                % 嵌套 Bus 不在 workspace 中，跳过
                nestedBusDetails.(nbName) = struct('error', 'Not found in workspace');
            end
        end
    end

    % ===== 组装结果 =====
    result.bus = struct();
    result.bus.name = busName;
    result.bus.elementCount = nElements;
    result.bus.elements = elemInfos;
    result.bus.usedByBlocks = usedByBlocks;
    result.bus.nestedBuses = nestedBuses;

    if ~isempty(fieldnames(nestedBusDetails))
        result.bus.nestedBusDetails = nestedBusDetails;
    end

    % ===== 生成 message =====
    msgParts = {};
    msgParts{end+1} = sprintf('Bus ''%s'': %d elements', busName, nElements); %#ok<AGROW>
    if ~isempty(nestedBuses)
        msgParts{end+1} = sprintf('%d nested buses', length(nestedBuses)); %#ok<AGROW>
    end
    if ~isempty(usedByBlocks)
        msgParts{end+1} = sprintf('used by %d blocks', length(usedByBlocks)); %#ok<AGROW>
    end

    result.message = strjoin(msgParts, ', ');
end


function usedByBlocks = find_bus_usage(busName)
% FIND_BUS_USAGE 查找使用指定 Bus 的模块

    usedByBlocks = {};

    % 查找 Bus Creator 模块
    try
        busCreators = find_system('SearchDepth', 0, 'BlockType', 'BusCreator');
        for bi = 1:length(busCreators)
            try
                outType = get_param(busCreators{bi}, 'OutDataTypeStr');
                if ~isempty(outType) && containsIgnoreCase(outType, busName)
                    usedByBlocks{end+1} = busCreators{bi}; %#ok<AGROW>
                end
            catch
            end
        end
    catch
    end

    % 查找 Bus Selector 模块
    try
        busSelectors = find_system('SearchDepth', 0, 'BlockType', 'BusSelector');
        for bi = 1:length(busSelectors)
            try
                outType = get_param(busSelectors{bi}, 'OutputSignalName');
                if ~isempty(outType) && containsIgnoreCase(outType, busName)
                    usedByBlocks{end+1} = busSelectors{bi}; %#ok<AGROW>
                end
            catch
            end
        end
    catch
    end

    % 查找 Inport/Outport 模块使用 Bus 数据类型
    try
        ports = find_system('SearchDepth', 0, 'BlockType', {'Inport', 'Outport'});
        for pi = 1:length(ports)
            try
                dataType = get_param(ports{pi}, 'OutDataTypeStr');
                if ~isempty(dataType) && containsIgnoreCase(dataType, busName)
                    usedByBlocks{end+1} = ports{pi}; %#ok<AGROW>
                end
            catch
            end
        end
    catch
    end
end


function found = containsIgnoreCase(str, pattern)
% CONTAINSIGNORECASE 大小写不敏感的包含检查（兼容 R2016a）
    found = ~isempty(strfind(lower(str), lower(pattern)));
end
