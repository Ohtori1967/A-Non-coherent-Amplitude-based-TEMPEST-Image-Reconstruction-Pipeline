function fname = pptCurrentFile()
%PPTCURRENTFILE Return current presentation file name or full path.
%
% Tries to obtain the currently active slideshow's presentation.
% Falls back to ActivePresentation if needed.

    app = actxGetRunningServer('PowerPoint.Application');

    % 优先从 SlideShowWindows 取当前放映对应的 Presentation
    try
        if app.SlideShowWindows.Count >= 1
            pres = app.SlideShowWindows.Item(1).Presentation;
            fullName = string(pres.FullName);

            if strlength(fullName) > 0
                fname = fullName;
                return;
            end

            % fallback: maybe unsaved / no path
            nameOnly = string(pres.Name);
            if strlength(nameOnly) > 0
                fname = nameOnly;
                return;
            end
        end
    catch
    end

    % 回退：ActivePresentation
    try
        pres = app.ActivePresentation;
        fullName = string(pres.FullName);

        if strlength(fullName) > 0
            fname = fullName;
            return;
        end

        nameOnly = string(pres.Name);
        if strlength(nameOnly) > 0
            fname = nameOnly;
            return;
        end
    catch ME
        error('pptCurrentFile:NoPresentation', ...
            'PowerPoint is running, but no active presentation was found: %s', ...
            ME.message);
    end

    error('pptCurrentFile:Unknown', ...
        'Failed to determine current PowerPoint file.');
end
