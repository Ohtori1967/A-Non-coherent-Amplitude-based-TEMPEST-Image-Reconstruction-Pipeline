function pptGotoSlide(slideIndex)
%PPTGOTOSLIDE Jump to a specific PowerPoint slide.
%   pptGotoSlide(slideIndex) jumps to the specified slide number.
%
%   Example:
%       pptGotoSlide(5)

    if nargin < 1
        error('pptGotoSlide:MissingInput', 'You must provide a slide index.');
    end

    if ~isscalar(slideIndex) || ~isnumeric(slideIndex) || slideIndex < 1 || floor(slideIndex) ~= slideIndex
        error('pptGotoSlide:InvalidInput', ...
            'slideIndex must be a positive integer.');
    end

    view = pptGetView();
    view.GotoSlide(slideIndex);
end