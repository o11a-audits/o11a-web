# o11a-web
The web client for o11a collaborative auditing

# Source Text Rendering

The o11a web client has a dynamic source text renderer, where it takes HTML output from the backend formatter and renders it based on the container's width. This way, the source text can always fit in its container without horizontal scrolling. This allows the web client to be flexible in how it displays source text to the user and provides for multi-pane views.

The dynamic formatting works as follows: The source text is rendered in a container. A JavaScript function initializes an internal state with a counter of 0 and an empty list of prior splits. It then runs a check on scrollWidth vs clientWidth to determine if the source text is overflowing horizontally. This check is attached to a resize event and will continually shrink or grow the source text as the container shrinks or grows. The overflow check is as follows:
If the text is overflowing:
1. Search for the .split<count> elements and their text to a newline to split the line. If none exist, do nothing further
2. Increment the counter by 1, indicating that it has split the element at that rank
3. Save the width that triggered this overflow, along with the split rank that the width triggered
4. Run again until the text is not overflowing
If the text is not overflowing:
1. Check if the width is greater than the most recent (smallest) width that caused an overflow. If it is not, do nothing further
3. Search for the .split<count> elements, changing their text to a space
4. Decrement the counter by 1.
5. Run again until the width is not greater than the most recent width that caused an overflow
