function pptNextSlide()
%PPTNEXTSLIDE Advance PowerPoint slide show to the next slide.

    view = pptGetView();
    view.Next;
end