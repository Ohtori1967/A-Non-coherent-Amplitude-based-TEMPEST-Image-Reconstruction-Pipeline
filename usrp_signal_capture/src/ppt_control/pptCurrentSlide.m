function idx = pptCurrentSlide()
%PPTCURRENTSLIDE Return current PowerPoint slide index.

    view = pptGetView();
    idx = view.Slide.SlideIndex;
end