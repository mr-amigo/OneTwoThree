import { useQuery } from "@tanstack/react-query"

import { api } from "@/lib/api"

export function useMe(enabled = true) {
  return useQuery({ queryKey: ["me"], queryFn: api.getMe, staleTime: Infinity, enabled })
}
