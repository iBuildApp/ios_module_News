headerdoc2html -j -o mNews/Documentation mNews/mNews.h     


gatherheaderdoc mNews/Documentation


sed -i.bak 's/<html><body>//g' mNews/Documentation/masterTOC.html
sed -i.bak 's|<\/body><\/html>||g' mNews/Documentation/masterTOC.html
sed -i.bak 's|<!DOCTYPE html PUBLIC "-//W3C//DTD HTML 4.0 Transitional//EN" "http://www.w3.org/TR/REC-html40/loose.dtd">||g' mNews/Documentation/masterTOC.html