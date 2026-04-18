function result = sl_bus_create(busName, elements, varargin)
% SL_BUS_CREATE 创建总线对象 — 从字段定义创建 Simulink.Bus → 保存到 workspace/dictionary/file
%   result = sl_bus_create('MyBus', elements)
%   result = sl_bus_create('MyBus', elements, 'saveTo', 'workspace', ...)
%
%   版本策略: 优先 R2022b+，R2016a 回退兼容
%
%   输入:
%     busName    - 总线对象名称（必选），如 'FlightData_Bus'
%     elements   - struct 数组，每个元素定义一个总线字段:
%                    .name        - 字段名（必选）
%                    .dataType    - 数据类型，默认 'double'
%                    .dimensions  - 维度，默认 1
%                    .complexity  - 复杂度 'real'/'imaginary'/'auto'，默认 'real'
%                    .samplingMode - 采样模式，默认 'Sample'
%     'saveTo'          - 保存目标: 'workspace'(默认)/'dictionary'/'file'
%     'dictionaryPath'  - 数据字典路径（saveTo='dictionary' 时必填）
%     'filePath'        - 保存文件路径（saveTo='file' 时必填）
%     'description'     - 总线描述信息
%     'overwrite'       - 是否覆盖已有同名总线，默认 false
%
%   输出: struct
%     .status   - 'ok' 或 'error'
%     .bus      - struct(.name, .elementCount, .elements, .savedTo, .verified)
%     .message  - 人类可读的总结信息
%     .error    - 错误信息（仅 status='error' 时）

    % ===== 解析参数 =====
    saveTo = 'workspace';
    dictionaryPath = '';
    filePath = '';
    description = '';
    overwrite = false;

    idx = 1;
    while idx <= length(varargin)
        if ischar(varargin{idx}) && idx < length(varargin)
            key = varargin{idx};
            val = varargin{idx+1};
            switch lower(key)
                case 'saveto'
                    saveTo = val;
                case 'dictionarypath'
                    dictionaryPath = val;
                case 'filepath'
                    filePath = val;
                case 'description'
                    description = val;
                case 'overwrite'
                    overwrite = val;
            end
        end
        idx = idx + 2;
    end

    result = struct('status', 'ok', 'bus', struct(), ...
        'message', '', 'error', '');

    % ===== 验证输入 =====
    if isempty(busName) || ~ischar(busName)
        result.status = 'error';
        result.error = 'busName must be a non-empty string';
        result.message = result.error;
        return;
    end

    if isempty(elements)
        result.status = 'error';
        result.error = 'elements must be a non-empty struct array';
        result.message = result.error;
        return;
    end

    % 确保 elements 是 struct 数组（不是 cell）
    if ~isstruct(elements)
        result.status = 'error';
        result.error = 'elements must be a struct array with .name field';
        result.message = result.error;
        return;
    end

    % ===== 检查同名总线是否已存在 =====
    busExists = false;
    try
        existingBus = evalin('base', busName);
        if isa(existingBus, 'Simulink.Bus')
            busExists = true;
        end
    catch
    end

    if busExists && ~overwrite
        result.status = 'error';
        result.error = ['Bus object ''' busName ''' already exists in workspace. Set overwrite=true to replace.'];
        result.message = result.error;
        return;
    end

    % ===== 创建 BusElement 数组 =====
    nElements = length(elements);
    busElements = [];

    for ei = 1:nElements
        elem = elements(ei);

        % 验证必填字段
        if ~isfield(elem, 'name')
            result.status = 'error';
            result.error = sprintf('Element %d missing required field: name', ei);
            result.message = result.error;
            return;
        end

        try
            be = Simulink.BusElement;
            be.Name = elem.name;

            % 设置数据类型
            if isfield(elem, 'dataType')
                be.DataType = elem.dataType;
            else
                be.DataType = 'double';
            end

            % 设置维度
            if isfield(elem, 'dimensions')
                if isnumeric(elem.dimensions)
                    be.Dimensions = elem.dimensions;
                elseif ischar(elem.dimensions)
                    be.Dimensions = str2double(elem.dimensions);
                    if isnan(be.Dimensions)
                        be.Dimensions = elem.dimensions; % 可能是变量名如 '[1 N]'
                    end
                end
            else
                be.Dimensions = 1;
            end

            % 设置复杂度
            if isfield(elem, 'complexity')
                be.Complexity = elem.complexity;
            else
                be.Complexity = 'real';
            end

            % 设置采样模式（R2016a 可能不支持）
            try
                if isfield(elem, 'samplingMode')
                    be.SamplingMode = elem.samplingMode;
                end
            catch
                % 旧版本可能没有 SamplingMode 属性
            end

            % 设置描述
            try
                if isfield(elem, 'description')
                    be.Description = elem.description;
                end
            catch
            end

            if isempty(busElements)
                busElements = be;
            else
                busElements = [busElements, be]; %#ok<AGROW>
            end

        catch ME
            result.status = 'error';
            result.error = sprintf('Failed to create BusElement for ''%s'': %s', elem.name, ME.message);
            result.message = result.error;
            return;
        end
    end

    % ===== 创建 Bus 对象 =====
    try
        bus = Simulink.Bus;
        bus.Elements = busElements;

        % 设置描述
        if ~isempty(description)
            try
                bus.Description = description;
            catch
            end
        end

    catch ME
        result.status = 'error';
        result.error = ['Failed to create Simulink.Bus: ' ME.message];
        result.message = result.error;
        return;
    end

    % ===== 保存到目标 =====
    savedTo = '';
    switch lower(saveTo)
        case 'workspace'
            assignin('base', busName, bus);
            savedTo = 'workspace';

        case 'dictionary'
            if isempty(dictionaryPath)
                result.status = 'error';
                result.error = 'dictionaryPath is required when saveTo=''dictionary''';
                result.message = result.error;
                return;
            end
            try
                dictObj = Simulink.data.dictionary.open(dictionaryPath);
                section = dictObj.getSection('DesignData');
                entry = section.addEntry(busName, bus);
                savedTo = ['dictionary: ' dictionaryPath];
            catch ME
                result.status = 'error';
                result.error = ['Failed to save to dictionary: ' ME.message];
                result.message = result.error;
                return;
            end

        case 'file'
            if isempty(filePath)
                result.status = 'error';
                result.error = 'filePath is required when saveTo=''file''';
                result.message = result.error;
                return;
            end
            try
                % 保存 Bus 对象到 .mat 文件
                ws = struct();
                ws.(busName) = bus;
                save(filePath, '-struct', 'ws');
                savedTo = ['file: ' filePath];
            catch ME
                result.status = 'error';
                result.error = ['Failed to save to file: ' ME.message];
                result.message = result.error;
                return;
            end

        otherwise
            result.status = 'error';
            result.error = ['Unknown saveTo target: ' saveTo];
            result.message = result.error;
            return;
    end

    % ===== 验证创建成功 =====
    verified = false;
    try
        verifyBus = evalin('base', busName);
        if isa(verifyBus, 'Simulink.Bus') && length(verifyBus.Elements) == nElements
            verified = true;
        end
    catch
    end

    % ===== 构建返回的元素信息 =====
    elemInfos = struct([]);
    for ei = 1:nElements
        elem = elements(ei);
        info = struct();
        info.name = elem.name;
        info.dataType = 'double';
        if isfield(elem, 'dataType')
            info.dataType = elem.dataType;
        end
        info.dimensions = '1';
        if isfield(elem, 'dimensions')
            if isnumeric(elem.dimensions)
                info.dimensions = num2str(elem.dimensions);
            else
                info.dimensions = elem.dimensions;
            end
        end
        info.complexity = 'real';
        if isfield(elem, 'complexity')
            info.complexity = elem.complexity;
        end

        if ei == 1
            elemInfos = info;
        else
            elemInfos = [elemInfos, info]; %#ok<AGROW>
        end
    end

    % ===== 组装结果 =====
    result.bus = struct( ...
        'name', busName, ...
        'elementCount', nElements, ...
        'elements', elemInfos, ...
        'savedTo', savedTo, ...
        'verified', verified);

    result.message = sprintf('Bus object ''%s'' created with %d elements, saved to %s', ...
        busName, nElements, savedTo);

    if ~verified
        result.message = [result.message ' (verification failed)'];
    end
end
