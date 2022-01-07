SELECT ST_Union(geom)
INTO merged
FROM public."Exports";